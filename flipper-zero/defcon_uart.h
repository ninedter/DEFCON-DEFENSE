#pragma once

#include <furi.h>
#include <furi_hal.h>

typedef struct DefconUart DefconUart;
typedef void (*DefconUartRxCallback)(const uint8_t* data, size_t length, void* context);

DefconUart* defcon_uart_alloc(DefconUartRxCallback callback, void* context);
void defcon_uart_tx(DefconUart* uart, const char* text);
void defcon_uart_free(DefconUart* uart);
