#include "defcon_uart.h"

#define DEFCON_UART_BAUDRATE    (115200)
#define DEFCON_UART_BUFFER_SIZE (1024)
#define DEFCON_UART_CHUNK_SIZE  (256)

typedef enum {
    DefconUartEventStop = (1U << 0),
    DefconUartEventRx = (1U << 1),
} DefconUartEvent;

struct DefconUart {
    FuriThread* thread;
    FuriStreamBuffer* stream;
    FuriHalSerialHandle* serial;
    DefconUartRxCallback callback;
    void* callback_context;
    uint8_t buffer[DEFCON_UART_CHUNK_SIZE];
};

static void
    defcon_uart_irq(FuriHalSerialHandle* handle, FuriHalSerialRxEvent event, void* context) {
    DefconUart* uart = context;
    if(event != FuriHalSerialRxEventData) return;

    const uint8_t byte = furi_hal_serial_async_rx(handle);
    furi_stream_buffer_send(uart->stream, &byte, 1, 0);
    furi_thread_flags_set(furi_thread_get_id(uart->thread), DefconUartEventRx);
}

static int32_t defcon_uart_worker(void* context) {
    DefconUart* uart = context;
    const uint32_t events_mask = DefconUartEventStop | DefconUartEventRx;

    while(true) {
        const uint32_t events =
            furi_thread_flags_wait(events_mask, FuriFlagWaitAny, FuriWaitForever);
        furi_check((events & FuriFlagError) == 0);
        if(events & DefconUartEventStop) break;

        if(events & DefconUartEventRx) {
            size_t length =
                furi_stream_buffer_receive(uart->stream, uart->buffer, sizeof(uart->buffer), 0);
            if(length && uart->callback) {
                uart->callback(uart->buffer, length, uart->callback_context);
            }
        }
    }

    return 0;
}

DefconUart* defcon_uart_alloc(DefconUartRxCallback callback, void* context) {
    DefconUart* uart = malloc(sizeof(DefconUart));
    memset(uart, 0, sizeof(DefconUart));

    uart->callback = callback;
    uart->callback_context = context;
    uart->stream = furi_stream_buffer_alloc(DEFCON_UART_BUFFER_SIZE, 1);
    uart->thread = furi_thread_alloc();
    furi_thread_set_name(uart->thread, "DefconDefenseRx");
    furi_thread_set_stack_size(uart->thread, 1536);
    furi_thread_set_context(uart->thread, uart);
    furi_thread_set_callback(uart->thread, defcon_uart_worker);
    furi_thread_start(uart->thread);

    uart->serial = furi_hal_serial_control_acquire(FuriHalSerialIdUsart);
    furi_check(uart->serial);
    furi_hal_serial_init(uart->serial, DEFCON_UART_BAUDRATE);
    furi_hal_serial_async_rx_start(uart->serial, defcon_uart_irq, uart, false);

    return uart;
}

void defcon_uart_tx(DefconUart* uart, const char* text) {
    furi_assert(uart);
    furi_assert(text);
    furi_hal_serial_tx(uart->serial, (const uint8_t*)text, strlen(text));
}

void defcon_uart_free(DefconUart* uart) {
    if(!uart) return;

    furi_hal_serial_async_rx_stop(uart->serial);
    furi_thread_flags_set(furi_thread_get_id(uart->thread), DefconUartEventStop);
    furi_thread_join(uart->thread);
    furi_thread_free(uart->thread);
    furi_stream_buffer_free(uart->stream);
    furi_hal_serial_deinit(uart->serial);
    furi_hal_serial_control_release(uart->serial);
    free(uart);
}
