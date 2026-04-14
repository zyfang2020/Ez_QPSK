#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "sleep.h"

#define DMA_DEV_ID         XPAR_AXIDMA_0_DEVICE_ID
#define RX_BUF_ADDR        0x1F000000U
#define RX_LEN_BYTES       8192U
#define SAMPLE_PRINT_COUNT 32U
#define DMA_POLL_US        100U
#define DMA_TIMEOUT_LOOPS  100000U

static XAxiDma AxiDma;

static int init_dma(XAxiDma *axi_dma)
{
    XAxiDma_Config *cfg_ptr;
    int status;

    cfg_ptr = XAxiDma_LookupConfig(DMA_DEV_ID);
    if (cfg_ptr == NULL) {
        xil_printf("ERR: XAxiDma_LookupConfig failed\r\n");
        return XST_FAILURE;
    }

    status = XAxiDma_CfgInitialize(axi_dma, cfg_ptr);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: XAxiDma_CfgInitialize failed: %d\r\n", status);
        return status;
    }

    if (XAxiDma_HasSg(axi_dma)) {
        xil_printf("ERR: design is configured as SG mode, example expects simple mode\r\n");
        return XST_FAILURE;
    }

    XAxiDma_Reset(axi_dma);
    while (!XAxiDma_ResetIsDone(axi_dma)) {
    }

    return XST_SUCCESS;
}

static int start_s2mm_transfer(XAxiDma *axi_dma, UINTPTR rx_addr, u32 rx_len)
{
    int status;

    Xil_DCacheFlushRange(rx_addr, rx_len);

    status = XAxiDma_SimpleTransfer(
        axi_dma,
        rx_addr,
        rx_len,
        XAXIDMA_DEVICE_TO_DMA
    );
    if (status != XST_SUCCESS) {
        xil_printf("ERR: XAxiDma_SimpleTransfer failed: %d\r\n", status);
        return status;
    }

    return XST_SUCCESS;
}

static int wait_s2mm_done(XAxiDma *axi_dma)
{
    u32 loops = 0;

    while (XAxiDma_Busy(axi_dma, XAXIDMA_DEVICE_TO_DMA)) {
        if (loops >= DMA_TIMEOUT_LOOPS) {
            xil_printf("ERR: DMA timeout\r\n");
            return XST_FAILURE;
        }
        usleep(DMA_POLL_US);
        loops++;
    }

    if (XAxiDma_ReadReg(axi_dma->RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET) &
        XAXIDMA_ERR_ALL_MASK) {
        xil_printf("ERR: DMA status indicates error, SR=0x%08lx\r\n",
                   (unsigned long)XAxiDma_ReadReg(
                       axi_dma->RegBase,
                       XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET));
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

static void dump_rx_samples(UINTPTR rx_addr, u32 rx_len)
{
    volatile u16 *buf;
    u32 sample_count;
    u32 i;

    Xil_DCacheInvalidateRange(rx_addr, rx_len);

    buf = (volatile u16 *)rx_addr;
    sample_count = rx_len / sizeof(u16);
    if (sample_count > SAMPLE_PRINT_COUNT) {
        sample_count = SAMPLE_PRINT_COUNT;
    }

    xil_printf("INFO: first %lu samples:\r\n", (unsigned long)sample_count);
    for (i = 0; i < sample_count; ++i) {
        xil_printf("[%02lu] 0x%04x\r\n", (unsigned long)i, buf[i]);
    }
}

int main(void)
{
    int status;

    xil_printf("\r\n");
    xil_printf("=== baremetal_dma_rx ===\r\n");
    xil_printf("DMA_DEV_ID   = %d\r\n", DMA_DEV_ID);
    xil_printf("RX_BUF_ADDR  = 0x%08lx\r\n", (unsigned long)RX_BUF_ADDR);
    xil_printf("RX_LEN_BYTES = %lu\r\n", (unsigned long)RX_LEN_BYTES);

    status = init_dma(&AxiDma);
    if (status != XST_SUCCESS) {
        xil_printf("FATAL: DMA init failed\r\n");
        return status;
    }

    xil_printf("INFO: starting S2MM transfer...\r\n");
    status = start_s2mm_transfer(&AxiDma, RX_BUF_ADDR, RX_LEN_BYTES);
    if (status != XST_SUCCESS) {
        xil_printf("FATAL: could not start S2MM transfer\r\n");
        return status;
    }

    status = wait_s2mm_done(&AxiDma);
    if (status != XST_SUCCESS) {
        xil_printf("FATAL: S2MM transfer did not complete cleanly\r\n");
        return status;
    }

    xil_printf("INFO: DMA transfer complete\r\n");
    dump_rx_samples(RX_BUF_ADDR, RX_LEN_BYTES);

    xil_printf("INFO: example finished, staying alive\r\n");
    while (1) {
        usleep(1000000U);
    }

    return 0;
}
