// SPDX-License-Identifier: GPL-2.0-only
/*
 * Lenovo Legion GameZone GPU-mode bridge for Linux.
 *
 * Exposes Lenovo GameZone WMI methods 63-66 through module parameters:
 *   support       - IsSupportIGPUMode (read only)
 *   mode          - Get/SetIGPUModeStatus (read/write)
 *   notify_dgpu   - NotifyDGPUStatus (read/write; read returns last value sent)
 *
 * This module deliberately uses Linux's exported GUID-based WMI API so it can
 * coexist with the in-tree lenovo_wmi_gamezone platform-profile driver.
 */

#include <linux/acpi.h>
#include <linux/errno.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/types.h>
#include <linux/unaligned.h>

#define LEGION_GAMEZONE_GUID "887B54E3-DDDC-4B2C-8B88-68A26A8835D0"

#define LEGION_METHOD_IGPU_SUPPORT 63
#define LEGION_METHOD_IGPU_GET     64
#define LEGION_METHOD_IGPU_SET     65
#define LEGION_METHOD_DGPU_NOTIFY  66

struct legion_wmi_method_args_32 {
	__le32 arg0;
	__le32 arg1;
};

static DEFINE_MUTEX(legion_wmi_lock);
static int last_notify_value = -1;
static u32 last_firmware_result;

static int legion_parse_u32_output(struct acpi_buffer *output, u32 *value)
{
	union acpi_object *object = output->pointer;

	if (!object)
		return -ENODATA;

	switch (object->type) {
	case ACPI_TYPE_INTEGER:
		*value = (u32)object->integer.value;
		return 0;
	case ACPI_TYPE_BUFFER:
		if (object->buffer.length < sizeof(u32))
			return -ENODATA;
		*value = get_unaligned_le32(object->buffer.pointer);
		return 0;
	default:
		return -EPROTO;
	}
}

static int legion_wmi_call(u32 method_id, const u32 *argument, u32 *result)
{
	struct acpi_buffer output = { ACPI_ALLOCATE_BUFFER, NULL };
	struct acpi_buffer input;
	struct legion_wmi_method_args_32 input_args = {};
	acpi_status status;
	int ret = 0;

	if (argument) {
		/* Lenovo methods use two 32-bit arguments even when only arg0 is set. */
		input_args.arg0 = cpu_to_le32(*argument);
		input.length = sizeof(input_args);
		input.pointer = &input_args;
	} else {
		/* Lenovo's in-tree helper also passes an explicit zero-length buffer. */
		input.length = 0;
		input.pointer = NULL;
	}

	mutex_lock(&legion_wmi_lock);
	status = wmi_evaluate_method(LEGION_GAMEZONE_GUID, 0, method_id,
				     &input, &output);
	if (ACPI_FAILURE(status)) {
		ret = -EIO;
		goto out;
	}

	if (result)
		ret = legion_parse_u32_output(&output, result);

out:
	kfree(output.pointer);
	mutex_unlock(&legion_wmi_lock);
	return ret;
}

static int legion_read_mode(u32 *mode)
{
	return legion_wmi_call(LEGION_METHOD_IGPU_GET, NULL, mode);
}

static int legion_mode_set(const char *value, const struct kernel_param *kp)
{
	u32 requested_mode;
	u32 firmware_result = 0;
	int ret;

	ret = kstrtou32(value, 0, &requested_mode);
	if (ret)
		return ret;

	if (requested_mode > 3)
		return -ERANGE;

	ret = legion_wmi_call(LEGION_METHOD_IGPU_SET, &requested_mode,
			      &firmware_result);
	if (ret == -ENODATA || ret == -EPROTO) {
		/* Some firmware accepts the setter but omits its documented result. */
		firmware_result = U32_MAX;
		ret = 0;
	}
	if (ret)
		return ret;

	last_firmware_result = firmware_result;
	pr_info("legion_gpu_mode: requested mode %u, firmware result %u\n",
		requested_mode, firmware_result);
	return 0;
}

static int legion_mode_get(char *buffer, const struct kernel_param *kp)
{
	u32 mode;
	int ret;

	ret = legion_read_mode(&mode);
	if (ret)
		return ret;

	return sysfs_emit(buffer, "%u\n", mode);
}

static const struct kernel_param_ops legion_mode_ops = {
	.set = legion_mode_set,
	.get = legion_mode_get,
};

module_param_cb(mode, &legion_mode_ops, NULL, 0644);
MODULE_PARM_DESC(mode,
	"Lenovo GPU mode: 0=Hybrid, 1=Hybrid-iGPU, 2=Auto, 3=dGPU");

static int legion_notify_set(const char *value, const struct kernel_param *kp)
{
	u32 requested_status;
	u32 firmware_result = 0;
	int ret;

	ret = kstrtou32(value, 0, &requested_status);
	if (ret)
		return ret;

	if (requested_status > 1)
		return -ERANGE;

	ret = legion_wmi_call(LEGION_METHOD_DGPU_NOTIFY, &requested_status,
			      &firmware_result);
	if (ret == -ENODATA || ret == -EPROTO) {
		/* Some firmware accepts the notification but returns no payload. */
		firmware_result = U32_MAX;
		ret = 0;
	}
	if (ret)
		return ret;

	last_notify_value = (int)requested_status;
	last_firmware_result = firmware_result;
	pr_info("legion_gpu_mode: notified dGPU status %u, firmware result %u\n",
		requested_status, firmware_result);
	return 0;
}

static int legion_notify_get(char *buffer, const struct kernel_param *kp)
{
	return sysfs_emit(buffer, "%d\n", last_notify_value);
}

static const struct kernel_param_ops legion_notify_ops = {
	.set = legion_notify_set,
	.get = legion_notify_get,
};

module_param_cb(notify_dgpu, &legion_notify_ops, NULL, 0600);
MODULE_PARM_DESC(notify_dgpu,
	"Call NotifyDGPUStatus: 0=not present, 1=present; read shows last value sent");

static int legion_support_get(char *buffer, const struct kernel_param *kp)
{
	u32 support;
	int ret;

	ret = legion_wmi_call(LEGION_METHOD_IGPU_SUPPORT, NULL, &support);
	if (ret)
		return ret;

	return sysfs_emit(buffer, "%u\n", support);
}

static const struct kernel_param_ops legion_support_ops = {
	.get = legion_support_get,
};

module_param_cb(support, &legion_support_ops, NULL, 0444);
MODULE_PARM_DESC(support, "Raw IsSupportIGPUMode firmware value");

module_param(last_firmware_result, uint, 0444);
MODULE_PARM_DESC(last_firmware_result,
	"Return value from the most recent SetIGPUModeStatus or NotifyDGPUStatus call");

static int __init legion_gpu_mode_init(void)
{
	u32 support;
	u32 mode;
	int ret;

	if (!wmi_has_guid(LEGION_GAMEZONE_GUID)) {
		pr_err("legion_gpu_mode: Lenovo GameZone WMI GUID is unavailable\n");
		return -ENODEV;
	}

	ret = legion_wmi_call(LEGION_METHOD_IGPU_SUPPORT, NULL, &support);
	if (ret) {
		pr_err("legion_gpu_mode: IsSupportIGPUMode failed: %d\n", ret);
		return ret;
	}

	if (!support) {
		pr_err("legion_gpu_mode: firmware reports no iGPU-mode support\n");
		return -EOPNOTSUPP;
	}

	ret = legion_read_mode(&mode);
	if (ret) {
		pr_err("legion_gpu_mode: GetIGPUModeStatus failed: %d\n", ret);
		return ret;
	}

	pr_info("legion_gpu_mode: loaded; support=%u current_mode=%u\n",
		support, mode);
	return 0;
}

static void __exit legion_gpu_mode_exit(void)
{
	pr_info("legion_gpu_mode: unloaded\n");
}

module_init(legion_gpu_mode_init);
module_exit(legion_gpu_mode_exit);

MODULE_AUTHOR("henryrts");
MODULE_DESCRIPTION("Lenovo Legion GameZone Hybrid-iGPU WMI bridge");
MODULE_LICENSE("GPL");
MODULE_SOFTDEP("pre: wmi");
