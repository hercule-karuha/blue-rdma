import os
import sys
import signal
import time
import mock_host

TOTAL_MEMORY_SIZE = 1024 * 1024 * 64
PGT_ENTRY_OFFSET = 0x200
PGT_ENTRY_CNT = 0x20
PGT_ENTRY_SIZE = 0x08
# PGT_MR0_BASE_VA = 0xFBABCDCEEEEE0001
PGT_MR0_BASE_VA = 0x0000000000000000

CMD_QUEUE_H2C_RINGBUF_START_PA = 0x00
CMD_QUEUE_C2H_RINGBUF_START_PA = 0x1000
SEND_QUEUE_RINGBUF_START_PA = 0x2000
META_REPORT_QUEUE_RINGBUF_START_PA = 0x3000

PGT_TABLE_START_PA_IN_HOST_MEM = 0x10000

HUGEPAGE_2M_ADDR_MASK = 0xFFFFFFFFFFE00000
HUGEPAGE_2M_BYTE_CNT = 0x200000

# MR_0_PA_START = 0x100000
MR_0_PA_START = 0x0

MR_0_PTE_COUNT = 0x20
MR_0_LENGTH = MR_0_PTE_COUNT * HUGEPAGE_2M_BYTE_CNT
print("MR_0_LENGTH=", hex(MR_0_LENGTH))

print("PGT_MR0_BASE_VA=", hex(PGT_MR0_BASE_VA))
# REQ_SIDE_VA_ADDR = (PGT_MR0_BASE_VA & HUGEPAGE_2M_ADDR_MASK) + 0x1FFFFE
REQ_SIDE_VA_ADDR = (PGT_MR0_BASE_VA & HUGEPAGE_2M_ADDR_MASK) + 0x200000
print("REQ_SIDE_VA_ADDR=", hex(REQ_SIDE_VA_ADDR))
RESP_SIDE_VA_ADDR = (PGT_MR0_BASE_VA & HUGEPAGE_2M_ADDR_MASK) + 0x90000
print("RESP_SIDE_VA_ADDR=", hex(RESP_SIDE_VA_ADDR))

SEND_SIDE_KEY = 0x6622
RECV_SIDE_KEY = 0x6622
PKEY_INDEX = 0

SEND_SIDE_QPN = 0x6611
SEND_SIDE_PD_HANDLER = 0x6611  # in practise, this should be returned by hardware

NIC_CONFIG_GATEWAY = 0x00000001
NIC_CONFIG_IPADDR = 0x11223344
NIC_CONFIG_NETMASK = 0xFFFFFFFF
NIC_CONFIG_MACADDR = 0xAABBCCDDEEFF


def run_test_case(test_case):
    shared_mem_file = os.environ.get("MOCK_HOST_SHARE_MEM_FILE", None)
    host_mem = mock_host.open_shared_mem_to_hw_simulator(
        TOTAL_MEMORY_SIZE, shared_mem_file)
    try:
        test_case(host_mem)
        sys.stdout.flush()
        sys.stderr.flush()
    except:
        import traceback
        traceback.print_exc()
        sys.stdout.flush()
        sys.stderr.flush()
        os.abort()

    finally:
        try:
            host_mem.close()
        except:
            pass

    os._exit(0)
