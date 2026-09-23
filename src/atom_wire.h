/* Copyright 2026 R4. SPDX-License-Identifier: Apache-2.0 */
#ifndef R4AMD_ATOM_WIRE_H
#define R4AMD_ATOM_WIRE_H
#include <stdint.h>
#include <stddef.h>
#include "atomfirmware.h"

/* Evaluate packed sizes/offsets in C. Zig's translated extern structs can
 * acquire natural padding, including nested camera data and encoder records.
 * These enum values describe the original bytes, never the translated ABI. */
#define R4AMD_SIZE(T) enum { r4amd_size_##T = sizeof(struct T) }
#define R4AMD_FIELD(T, F) enum { r4amd_offset_##T##_##F = offsetof(struct T, F) }
R4AMD_SIZE(atom_rom_header_v2_2);
R4AMD_FIELD(atom_rom_header_v2_2, subsystem_vendor_id);
R4AMD_FIELD(atom_rom_header_v2_2, subsystem_id);
R4AMD_FIELD(atom_rom_header_v2_2, pci_info_offset);
R4AMD_FIELD(atom_rom_header_v2_2, masterdatatable_offset);
R4AMD_FIELD(atom_rom_header_v2_2, masterhwfunction_offset);
R4AMD_SIZE(atom_master_data_table_v2_1);
R4AMD_SIZE(atom_master_list_of_data_tables_v2_1);
R4AMD_FIELD(atom_master_list_of_data_tables_v2_1, dce_info);
R4AMD_FIELD(atom_master_list_of_data_tables_v2_1, smu_info);
R4AMD_FIELD(atom_master_list_of_data_tables_v2_1, powerplayinfo);
R4AMD_FIELD(atom_master_list_of_data_tables_v2_1, gpio_pin_lut);
R4AMD_FIELD(atom_master_list_of_data_tables_v2_1, integratedsysteminfo);
R4AMD_FIELD(atom_master_list_of_data_tables_v2_1, lcd_info);
R4AMD_FIELD(atom_master_list_of_data_tables_v2_1, firmwareinfo);
R4AMD_FIELD(atom_master_list_of_data_tables_v2_1, vram_usagebyfirmware);
R4AMD_FIELD(atom_master_list_of_data_tables_v2_1, displayobjectinfo);
R4AMD_SIZE(atom_display_controller_info_v4_1);
R4AMD_SIZE(atom_display_controller_info_v4_2);
R4AMD_FIELD(atom_display_controller_info_v4_1, dce_refclk_10khz);
R4AMD_FIELD(atom_display_controller_info_v4_2, dce_refclk_10khz);
R4AMD_SIZE(atom_smu_info_v3_1);
R4AMD_SIZE(atom_smu_info_v3_2);
R4AMD_SIZE(atom_smu_info_v3_3);
R4AMD_FIELD(atom_smu_info_v3_1, core_refclk_10khz);
R4AMD_FIELD(atom_smu_info_v3_2, core_refclk_10khz);
R4AMD_FIELD(atom_smu_info_v3_3, core_refclk_10khz);
R4AMD_SIZE(atom_gpio_pin_assignment);
R4AMD_FIELD(atom_gpio_pin_assignment, gpio_id);
R4AMD_FIELD(atom_gpio_pin_assignment, data_a_reg_index);
R4AMD_FIELD(atom_gpio_pin_assignment, gpio_bitshift);
R4AMD_FIELD(atom_gpio_pin_assignment, gpio_mask_bitshift);
R4AMD_SIZE(atom_integrated_system_info_v1_11);
R4AMD_SIZE(atom_integrated_system_info_v1_12);
#define R4AMD_INTEGRATED(T) \
    R4AMD_FIELD(T, extdispconninfo); \
    R4AMD_FIELD(T, vbios_misc); \
    R4AMD_FIELD(T, gpucapinfo); \
    R4AMD_FIELD(T, system_config); \
    R4AMD_FIELD(T, memorytype); \
    R4AMD_FIELD(T, umachannelnumber); \
    R4AMD_FIELD(T, backlight_pwm_hz); \
    R4AMD_FIELD(T, min_allowed_bl_level)
#define R4AMD_DELAYS(T) \
    R4AMD_FIELD(T, pwr_on_digon_to_de); \
    R4AMD_FIELD(T, pwr_on_de_to_vary_bl); \
    R4AMD_FIELD(T, pwr_down_vary_bloff_to_de); \
    R4AMD_FIELD(T, pwr_down_de_to_digoff); \
    R4AMD_FIELD(T, pwr_off_delay); \
    R4AMD_FIELD(T, pwr_on_vary_bl_to_blon); \
    R4AMD_FIELD(T, pwr_down_bloff_to_vary_bloff)
R4AMD_INTEGRATED(atom_integrated_system_info_v1_11);
R4AMD_INTEGRATED(atom_integrated_system_info_v1_12);
R4AMD_DELAYS(atom_integrated_system_info_v1_11);
R4AMD_DELAYS(atom_integrated_system_info_v1_12);
R4AMD_SIZE(atom_external_display_connection_info);
R4AMD_FIELD(atom_external_display_connection_info, guid);
R4AMD_FIELD(atom_external_display_connection_info, path);
R4AMD_FIELD(atom_external_display_connection_info, checksum);
R4AMD_SIZE(atom_ext_display_path);
R4AMD_FIELD(atom_ext_display_path, connectorobjid);
R4AMD_FIELD(atom_ext_display_path, auxddclut_index);
R4AMD_FIELD(atom_ext_display_path, hpdlut_index);
R4AMD_FIELD(atom_ext_display_path, ext_encoder_objid);
R4AMD_FIELD(atom_ext_display_path, device_tag);
R4AMD_FIELD(atom_ext_display_path, device_acpi_enum);
R4AMD_FIELD(atom_ext_display_path, channelmapping);
R4AMD_FIELD(atom_ext_display_path, chpninvert);
R4AMD_FIELD(atom_ext_display_path, caps);
R4AMD_SIZE(lcd_info_v2_1);
R4AMD_DELAYS(lcd_info_v2_1);
R4AMD_FIELD(lcd_info_v2_1, lcd_timing);
R4AMD_FIELD(lcd_info_v2_1, panel_bpc);
R4AMD_FIELD(lcd_info_v2_1, backlight_pwm);
R4AMD_FIELD(lcd_info_v2_1, min_allowed_bl_level);
R4AMD_FIELD(lcd_info_v2_1, max_allowed_bl_level);
R4AMD_FIELD(lcd_info_v2_1, bootup_bl_level);
R4AMD_SIZE(atom_dtd_format);
R4AMD_FIELD(atom_dtd_format, h_active);
R4AMD_FIELD(atom_dtd_format, v_active);
R4AMD_FIELD(atom_dtd_format, h_blanking_time);
R4AMD_FIELD(atom_dtd_format, v_blanking_time);
R4AMD_FIELD(atom_dtd_format, h_sync_offset);
R4AMD_FIELD(atom_dtd_format, h_sync_width);
R4AMD_FIELD(atom_dtd_format, v_sync_offset);
R4AMD_FIELD(atom_dtd_format, v_syncwidth);
R4AMD_FIELD(atom_dtd_format, pixclk);
R4AMD_FIELD(atom_dtd_format, miscinfo);
R4AMD_SIZE(atom_firmware_info_v3_1);
R4AMD_SIZE(atom_firmware_info_v3_2);
R4AMD_FIELD(atom_firmware_info_v3_1, firmware_revision);
R4AMD_FIELD(atom_firmware_info_v3_1, bootup_sclk_in10khz);
R4AMD_FIELD(atom_firmware_info_v3_1, bootup_mclk_in10khz);
R4AMD_FIELD(atom_firmware_info_v3_1, bios_scratch_reg_startaddr);
R4AMD_SIZE(vram_usagebyfirmware_v2_1);
R4AMD_FIELD(vram_usagebyfirmware_v2_1, start_address_in_kb);
R4AMD_FIELD(vram_usagebyfirmware_v2_1, used_by_firmware_in_kb);
R4AMD_FIELD(vram_usagebyfirmware_v2_1, used_by_driver_in_kb);
R4AMD_SIZE(display_object_info_table_v1_4);
R4AMD_SIZE(display_object_info_table_v1_5);
R4AMD_FIELD(display_object_info_table_v1_4, number_of_path);
R4AMD_SIZE(atom_display_object_path_v2);
R4AMD_SIZE(atom_display_object_path_v3);
R4AMD_FIELD(atom_display_object_path_v2, display_objid);
R4AMD_FIELD(atom_display_object_path_v2, encoderobjid);
R4AMD_FIELD(atom_display_object_path_v2, extencoderobjid);
R4AMD_FIELD(atom_display_object_path_v2, device_tag);
R4AMD_FIELD(atom_display_object_path_v2, disp_recordoffset);
R4AMD_FIELD(atom_display_object_path_v2, encoder_recordoffset);
R4AMD_FIELD(atom_display_object_path_v2, extencoder_recordoffset);
R4AMD_SIZE(atom_encoder_caps_record);
R4AMD_FIELD(atom_encoder_caps_record, encodercaps);
R4AMD_SIZE(atom_i2c_record);
R4AMD_FIELD(atom_i2c_record, i2c_id);
R4AMD_FIELD(atom_i2c_record, i2c_slave_addr);
R4AMD_SIZE(atom_hpd_int_record);
R4AMD_FIELD(atom_hpd_int_record, pin_id);
R4AMD_FIELD(atom_hpd_int_record, plugin_pin_state);
R4AMD_SIZE(atom_connector_hpdpin_lut_record);
R4AMD_FIELD(atom_connector_hpdpin_lut_record, hpd_pin_map);
R4AMD_SIZE(atom_connector_auxddc_lut_record);
R4AMD_FIELD(atom_connector_auxddc_lut_record, aux_ddc_map);
#undef R4AMD_DELAYS
#undef R4AMD_INTEGRATED
#undef R4AMD_FIELD
#undef R4AMD_SIZE
#endif
