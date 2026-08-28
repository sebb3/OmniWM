CC := xcrun clang
LIPO := xcrun lipo
CFLAGS := -std=c11 -Wall -Wextra -Wpedantic -Werror -O0 -g
BUILD_DIR := build
PAYLOAD_ARM64 := $(BUILD_DIR)/libHS2DockWindowSpike.arm64.dylib
PAYLOAD_ARM64E := $(BUILD_DIR)/libHS2DockWindowSpike.arm64e.dylib
PAYLOAD := $(BUILD_DIR)/libHS2DockWindowSpike.dylib
CLIENT := $(BUILD_DIR)/hs2-dock-window-spike
V2_TEST_HARNESS := $(BUILD_DIR)/dock-protocol-v2-tests

OPERATION_TEST_HARNESS := $(BUILD_DIR)/dock-operation-tests
V2_SOCKET_TEST_HARNESS := $(BUILD_DIR)/dock-protocol-v2-socket-tests
PAYLOAD_LIFECYCLE_TEST := $(BUILD_DIR)/dock-payload-lifecycle-tests
CLIENT_PEER_LOSS_TEST := $(BUILD_DIR)/dock-client-peer-loss-tests
WORKSPACE_TRANSITION_TEST := $(BUILD_DIR)/dock-workspace-transition-tests

V2_TEST_ASAN := $(BUILD_DIR)/dock-protocol-v2-tests-asan
OPERATION_TEST_ASAN := $(BUILD_DIR)/dock-operation-tests-asan
V2_SOCKET_TEST_ASAN := $(BUILD_DIR)/dock-protocol-v2-socket-tests-asan
WORKSPACE_TRANSITION_TEST_ASAN := $(BUILD_DIR)/dock-workspace-transition-tests-asan
SANITIZE_FLAGS := -fsanitize=address,undefined -fno-sanitize-recover=all

.PHONY: all clean test test-v2 sanitize analyze

all: $(PAYLOAD) $(CLIENT)

test: $(PAYLOAD) $(V2_TEST_HARNESS) $(OPERATION_TEST_HARNESS) $(V2_SOCKET_TEST_HARNESS) $(PAYLOAD_LIFECYCLE_TEST) $(CLIENT_PEER_LOSS_TEST) $(WORKSPACE_TRANSITION_TEST)
	$(V2_TEST_HARNESS)
	$(OPERATION_TEST_HARNESS)
	$(V2_SOCKET_TEST_HARNESS)
	$(PAYLOAD_LIFECYCLE_TEST)
	$(CLIENT_PEER_LOSS_TEST)
	$(WORKSPACE_TRANSITION_TEST)

test-v2: test

sanitize: $(V2_TEST_ASAN) $(OPERATION_TEST_ASAN) $(V2_SOCKET_TEST_ASAN) $(WORKSPACE_TRANSITION_TEST_ASAN)
	$(V2_TEST_ASAN)
	$(OPERATION_TEST_ASAN)
	$(V2_SOCKET_TEST_ASAN)
	$(WORKSPACE_TRANSITION_TEST_ASAN)

# Static analysis over every active C source, warnings fatal. Never loads the
# payload or contacts the Dock; it only parses and analyzes source.
analyze: Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Sources/Payload/payload_server.c Sources/Payload/operation_dispatch.c Sources/Payload/workspace_transition.c Sources/Payload/payload.c Sources/Client/main.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I Sources/Protocol -I Sources/Payload --analyze \
		Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c \
		Sources/Payload/payload_server.c Sources/Payload/operation_dispatch.c \
		Sources/Payload/workspace_transition.c \
		Sources/Payload/payload.c Sources/Client/main.c
	rm -f *.plist

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(PAYLOAD_ARM64): Sources/Payload/payload.c Sources/Payload/payload_server.c Sources/Payload/operation_dispatch.c Sources/Payload/workspace_transition.c Sources/Payload/payload_server.h Sources/Payload/operation_dispatch.h Sources/Payload/workspace_transition.h Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Sources/Protocol/protocol_v2.h Sources/Protocol/protocol_v2_server.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I Sources/Protocol -I Sources/Payload -arch arm64 -dynamiclib -fPIC -framework CoreFoundation -framework CoreGraphics -o $@ Sources/Payload/payload.c Sources/Payload/payload_server.c Sources/Payload/operation_dispatch.c Sources/Payload/workspace_transition.c Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c -lpthread

$(PAYLOAD_ARM64E): Sources/Payload/payload.c Sources/Payload/payload_server.c Sources/Payload/operation_dispatch.c Sources/Payload/workspace_transition.c Sources/Payload/payload_server.h Sources/Payload/operation_dispatch.h Sources/Payload/workspace_transition.h Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Sources/Protocol/protocol_v2.h Sources/Protocol/protocol_v2_server.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I Sources/Protocol -I Sources/Payload -arch arm64e -dynamiclib -fPIC -framework CoreFoundation -framework CoreGraphics -o $@ Sources/Payload/payload.c Sources/Payload/payload_server.c Sources/Payload/operation_dispatch.c Sources/Payload/workspace_transition.c Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c -lpthread

$(PAYLOAD): $(PAYLOAD_ARM64) $(PAYLOAD_ARM64E)
	$(LIPO) -create -output $@ $^

$(CLIENT): Sources/Client/main.c Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I Sources/Protocol -arch arm64 -o $@ Sources/Client/main.c Sources/Protocol/protocol_v2.c

$(V2_TEST_HARNESS): Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Sources/Protocol/protocol_v2.h Sources/Protocol/protocol_v2_server.h Tests/protocol_v2_tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I Sources/Protocol -arch arm64 -o $@ Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Tests/protocol_v2_tests.c

$(OPERATION_TEST_HARNESS): Sources/Payload/operation_dispatch.c Sources/Payload/operation_dispatch.h Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Sources/Protocol/protocol_v2.h Sources/Protocol/protocol_v2_server.h Tests/operation_dispatch_tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I Sources/Protocol -I Sources/Payload -arch arm64 -framework CoreGraphics -o $@ Sources/Payload/operation_dispatch.c Sources/Payload/workspace_transition.c Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Tests/operation_dispatch_tests.c

$(V2_SOCKET_TEST_HARNESS): Sources/Payload/payload_server.c Sources/Payload/payload_server.h Sources/Payload/operation_dispatch.c Sources/Payload/operation_dispatch.h Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Sources/Protocol/protocol_v2.h Sources/Protocol/protocol_v2_server.h Tests/protocol_v2_socket_tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I Sources/Protocol -I Sources/Payload -arch arm64 -framework CoreGraphics -o $@ Sources/Payload/payload_server.c Sources/Payload/operation_dispatch.c Sources/Payload/workspace_transition.c Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Tests/protocol_v2_socket_tests.c

$(PAYLOAD_LIFECYCLE_TEST): Tests/payload_lifecycle_tests.c Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2.h $(PAYLOAD) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I Sources/Protocol -arch arm64 -o $@ Tests/payload_lifecycle_tests.c Sources/Protocol/protocol_v2.c

$(CLIENT_PEER_LOSS_TEST): Tests/client_peer_loss_tests.c Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2.h $(CLIENT) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I Sources/Protocol -arch arm64 -o $@ Tests/client_peer_loss_tests.c Sources/Protocol/protocol_v2.c

$(V2_TEST_ASAN): Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Sources/Protocol/protocol_v2.h Sources/Protocol/protocol_v2_server.h Tests/protocol_v2_tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -I Sources/Protocol -arch arm64 -o $@ Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Tests/protocol_v2_tests.c

$(OPERATION_TEST_ASAN): Sources/Payload/operation_dispatch.c Sources/Payload/operation_dispatch.h Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Sources/Protocol/protocol_v2.h Sources/Protocol/protocol_v2_server.h Tests/operation_dispatch_tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -I Sources/Protocol -I Sources/Payload -arch arm64 -framework CoreGraphics -o $@ Sources/Payload/operation_dispatch.c Sources/Payload/workspace_transition.c Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Tests/operation_dispatch_tests.c

$(V2_SOCKET_TEST_ASAN): Sources/Payload/payload_server.c Sources/Payload/payload_server.h Sources/Payload/operation_dispatch.c Sources/Payload/operation_dispatch.h Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Sources/Protocol/protocol_v2.h Sources/Protocol/protocol_v2_server.h Tests/protocol_v2_socket_tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -I Sources/Protocol -I Sources/Payload -arch arm64 -framework CoreGraphics -o $@ Sources/Payload/payload_server.c Sources/Payload/operation_dispatch.c Sources/Payload/workspace_transition.c Sources/Protocol/protocol_v2.c Sources/Protocol/protocol_v2_server.c Tests/protocol_v2_socket_tests.c

$(WORKSPACE_TRANSITION_TEST): Sources/Payload/workspace_transition.c Sources/Payload/workspace_transition.h Sources/Payload/operation_dispatch.h Tests/workspace_transition_tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I Sources/Protocol -I Sources/Payload -arch arm64 -framework CoreFoundation -framework CoreGraphics -o $@ Sources/Payload/workspace_transition.c Tests/workspace_transition_tests.c

$(WORKSPACE_TRANSITION_TEST_ASAN): Sources/Payload/workspace_transition.c Sources/Payload/workspace_transition.h Sources/Payload/operation_dispatch.h Tests/workspace_transition_tests.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(SANITIZE_FLAGS) -I Sources/Protocol -I Sources/Payload -arch arm64 -framework CoreFoundation -framework CoreGraphics -o $@ Sources/Payload/workspace_transition.c Tests/workspace_transition_tests.c

clean:
	rm -rf $(BUILD_DIR)
