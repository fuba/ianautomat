# Responses streaming fix

Build 0.1.0 (1) could pause with no counted tokens because Foundation's asynchronous line iterator skipped the empty lines that delimit server-sent events. The event reader now consumes the byte stream and waits for a complete `response.completed` frame before accepting model output.

Goal logs distinguish model refusals, incomplete responses, and malformed stream events. HTTP and streamed API failures include the available status, error code, parameter name, and request ID. Raw error bodies are kept out of the log.

The iPhone app can use notification text supplied as goal input. iOS exposes delivered notifications to the app that sent them, so the iPhone app cannot fetch the contents of Notification Center across apps.
