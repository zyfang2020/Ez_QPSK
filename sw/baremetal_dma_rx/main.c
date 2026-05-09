#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "sleep.h"

#define DMA_DEV_ID             XPAR_AXIDMA_0_DEVICE_ID
#define RX_BUF_ADDR            0x1F000000U
#define ADC_SAMPLE_DW          10U
#define ADC_SAMPLE_MASK        ((1U << ADC_SAMPLE_DW) - 1U)
#define DMA_PKT_SAMPLES        100000U
#define DMA_PKT_BYTES          (DMA_PKT_SAMPLES * sizeof(u16))
#define UART_EXPORT_SAMPLES    DMA_PKT_SAMPLES
#define CAPTURE_PKT_COUNT      ((UART_EXPORT_SAMPLES + DMA_PKT_SAMPLES - 1U) / DMA_PKT_SAMPLES)
#define CAPTURE_TOTAL_SAMPLES  (CAPTURE_PKT_COUNT * DMA_PKT_SAMPLES)
#define CAPTURE_TOTAL_BYTES    (CAPTURE_TOTAL_SAMPLES * sizeof(u16))
#define SAMPLE_PRINT_COUNT     32U
#define DMA_TIMEOUT_LOOPS      100000000U
#define UART_FRAME_MAGIC       "QPSKDMA1"
#define UART_FRAME_MAGIC_LEN   8U
#define UART_FRAME_VERSION     1U

static XAxiDma AxiDma;

extern void outbyte(char c);

static u16 sanitize_sample(u16 sample)
{
    return (u16)(sample & ADC_SAMPLE_MASK);
}

static u32 get_s2mm_status(const XAxiDma *axi_dma)
{
    return XAxiDma_ReadReg(axi_dma->RegBase, XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET);
}

static void prepare_rx_capture_area(UINTPTR rx_addr, u32 rx_len)
{
    /*
     * S2MM simple mode 每次只能重新 arm 一包。这里把 RX 区域的 cache
     * 维护前移到采集开始前，避免多包抓取时在每个包边界重复 flush，
     * 尽量缩短软件侧重新 arm 的空窗。
     */
    Xil_DCacheFlushRange(rx_addr, rx_len);
}

static int init_dma(XAxiDma *axi_dma)
{
    XAxiDma_Config *cfg_ptr;
    int status;
    u32 loops = 0;

    xil_printf("BOOT: dma_lookup\r\n");
    cfg_ptr = XAxiDma_LookupConfig(DMA_DEV_ID);
    if (cfg_ptr == NULL) {
        xil_printf("ERR: XAxiDma_LookupConfig failed\r\n");
        return XST_FAILURE;
    }

    xil_printf("BOOT: dma_cfg_init\r\n");
    status = XAxiDma_CfgInitialize(axi_dma, cfg_ptr);
    if (status != XST_SUCCESS) {
        xil_printf("ERR: XAxiDma_CfgInitialize failed: %d\r\n", status);
        return status;
    }

    xil_printf("BOOT: dma_mode_check\r\n");
    if (XAxiDma_HasSg(axi_dma)) {
        xil_printf("ERR: design is configured as SG mode, example expects simple mode\r\n");
        return XST_FAILURE;
    }

    xil_printf("BOOT: dma_reset_start\r\n");
    XAxiDma_Reset(axi_dma);
    while (!XAxiDma_ResetIsDone(axi_dma)) {
        if (loops++ >= DMA_TIMEOUT_LOOPS) {
            xil_printf("ERR: DMA reset timeout\r\n");
            return XST_FAILURE;
        }
    }
    xil_printf("BOOT: dma_reset_done\r\n");

    return XST_SUCCESS;
}

static int start_s2mm_transfer(XAxiDma *axi_dma, UINTPTR rx_addr, u32 rx_len)
{
    int status;

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
    u32 sr = 0;

    while (1) {
        sr = get_s2mm_status(axi_dma);
        if ((sr & XAXIDMA_ERR_ALL_MASK) != 0U) {
            xil_printf("ERR: DMA status indicates error, SR=0x%08lx\r\n",
                       (unsigned long)sr);
            return XST_FAILURE;
        }

        if (!XAxiDma_Busy(axi_dma, XAXIDMA_DEVICE_TO_DMA)) {
            break;
        }

        if (loops >= DMA_TIMEOUT_LOOPS) {
            xil_printf("ERR: DMA timeout, SR=0x%08lx\r\n",
                       (unsigned long)sr);
            return XST_FAILURE;
        }
        loops++;
    }

    sr = get_s2mm_status(axi_dma);
    if ((sr & XAXIDMA_ERR_ALL_MASK) != 0U) {
        xil_printf("ERR: DMA status indicates error, SR=0x%08lx\r\n",
                   (unsigned long)sr);
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

static int capture_packet_sequence(XAxiDma *axi_dma, UINTPTR base_addr, u32 pkt_count)
{
    u32 pkt_idx;
    int status;

    for (pkt_idx = 0; pkt_idx < pkt_count; ++pkt_idx) {
        UINTPTR pkt_addr = base_addr + (UINTPTR)(pkt_idx * DMA_PKT_BYTES);

        status = start_s2mm_transfer(axi_dma, pkt_addr, DMA_PKT_BYTES);
        if (status != XST_SUCCESS) {
            xil_printf("ERR: could not start packet %lu\r\n",
                       (unsigned long)(pkt_idx + 1U));
            return status;
        }

        status = wait_s2mm_done(axi_dma);
        if (status != XST_SUCCESS) {
            xil_printf("ERR: packet %lu did not complete cleanly\r\n",
                       (unsigned long)(pkt_idx + 1U));
            return status;
        }
    }

    return XST_SUCCESS;
}

static const u16 *get_rx_buf(UINTPTR rx_addr, u32 rx_len)
{
    Xil_DCacheInvalidateRange(rx_addr, rx_len);
    return (const u16 *)rx_addr;
}

static void dump_rx_samples(const u16 *buf, u32 sample_count)
{
    u32 i;

    if (sample_count > SAMPLE_PRINT_COUNT) {
        sample_count = SAMPLE_PRINT_COUNT;
    }

    xil_printf("INFO: first %lu samples:\r\n", (unsigned long)sample_count);
    for (i = 0; i < sample_count; ++i) {
        xil_printf("[%02lu] 0x%04x\r\n",
                   (unsigned long)i,
                   (unsigned int)sanitize_sample(buf[i]));
    }
}

static u32 calc_sample_checksum(const u16 *buf, u32 sample_count)
{
    u32 checksum = 0;
    u32 i;

    for (i = 0; i < sample_count; ++i) {
        checksum += sanitize_sample(buf[i]);
    }

    return checksum;
}

static u32 count_upper_bit_anomalies(const u16 *buf, u32 sample_count)
{
    u32 i;
    u32 count = 0;

    for (i = 0; i < sample_count; ++i) {
        if ((buf[i] & (u16)(~ADC_SAMPLE_MASK)) != 0U) {
            count++;
        }
    }

    return count;
}

static void uart_send_byte(u8 byte)
{
    outbyte((char)byte);
}

static void uart_send_u32_le(u32 value)
{
    uart_send_byte((u8)(value & 0xFFU));
    uart_send_byte((u8)((value >> 8) & 0xFFU));
    uart_send_byte((u8)((value >> 16) & 0xFFU));
    uart_send_byte((u8)((value >> 24) & 0xFFU));
}

static void uart_send_buf(const u8 *buf, u32 len)
{
    u32 i;

    for (i = 0; i < len; ++i) {
        uart_send_byte(buf[i]);
    }
}

static void uart_send_capture_frame(const u16 *buf, u32 sample_count)
{
    u32 payload_bytes = sample_count * sizeof(u16);
    u32 checksum = calc_sample_checksum(buf, sample_count);
    u32 i;

    uart_send_buf((const u8 *)UART_FRAME_MAGIC, UART_FRAME_MAGIC_LEN);
    uart_send_u32_le(UART_FRAME_VERSION);
    uart_send_u32_le(sample_count);
    uart_send_u32_le(payload_bytes);
    uart_send_u32_le(checksum);

    for (i = 0; i < sample_count; ++i) {
        u16 sample = sanitize_sample(buf[i]);
        uart_send_byte((u8)(sample & 0xFFU));
        uart_send_byte((u8)((sample >> 8) & 0xFFU));
    }

    (void)checksum;
}

int main(void)
{
    int status;
    const u16 *rx_buf;
    u32 upper_bit_anomalies;
    u32 frame_idx = 0;

    xil_printf("\r\nBOOT: baremetal_dma_rx\r\n");
    xil_printf("BOOT: pre_dma_init\r\n");

    status = init_dma(&AxiDma);
    if (status != XST_SUCCESS) {
        xil_printf("FATAL: DMA init failed\r\n");
        return status;
    }
    xil_printf("BOOT: dma_init_ok\r\n");

    while (1) {
        if (frame_idx == 0U) {
            xil_printf("BOOT: capture_start\r\n");
        }
        prepare_rx_capture_area(RX_BUF_ADDR, CAPTURE_TOTAL_BYTES);
        status = capture_packet_sequence(&AxiDma, RX_BUF_ADDR, CAPTURE_PKT_COUNT);
        if (status != XST_SUCCESS) {
            xil_printf("FATAL: packet capture failed on frame %lu\r\n",
                       (unsigned long)(frame_idx + 1U));
            return status;
        }

        rx_buf = get_rx_buf(RX_BUF_ADDR, CAPTURE_TOTAL_BYTES);
        if (frame_idx == 0U) {
            upper_bit_anomalies = count_upper_bit_anomalies(rx_buf, UART_EXPORT_SAMPLES);
            xil_printf("BOOT: first_frame_ok\r\n");
            xil_printf("INFO: first frame upper-bit anomalies = %lu\r\n",
                       (unsigned long)upper_bit_anomalies);
            dump_rx_samples(rx_buf, UART_EXPORT_SAMPLES);
            xil_printf("INFO: entering continuous UART streaming mode\r\n");
        }

        uart_send_capture_frame(rx_buf, UART_EXPORT_SAMPLES);
        frame_idx++;
    }

    return 0;
}
