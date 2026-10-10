/* fpga_pci.h - SIMULATION ONLY. The subset of the AWS FPGA SDK API the organisers'
 * emu.c uses, so it compiles unmodified against our Verilator model of top.sv
 * (stage4/sim/emu_sys/sim_main.cpp provides the functions). */
#ifndef FPGA_PCI_H
#define FPGA_PCI_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int pci_bar_handle_t;
#define PCI_BAR_HANDLE_INIT (-1)
#define FPGA_APP_PF 0
#define APP_PF_BAR0 0

int fpga_pci_attach(int slot_id, int pf_id, int bar_id, uint32_t flags, pci_bar_handle_t *handle);
int fpga_pci_detach(pci_bar_handle_t handle);
int fpga_pci_peek(pci_bar_handle_t handle, uint64_t offset, uint32_t *value);
int fpga_pci_poke(pci_bar_handle_t handle, uint64_t offset, uint32_t value);

#ifdef __cplusplus
}
#endif
#endif
