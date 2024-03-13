import Connectable :: *;
import ClientServer :: *;
import GetPut :: *;
import FIFOF :: *;
import PAClib :: *;
import Clocks :: *;
import BRAM :: *;

import RQ :: *;
import QPContext :: *;
import MetaData :: *;
import DataTypes :: *;
import InputPktHandle :: *;
import RdmaUtils :: *;
import PrimUtils :: *;
import StmtFSM::*;
import Axi4LiteTypes :: *;
import SemiFifo :: *;
import UdpIpEthCmacRxTx::*;

import ExtractAndPrependPipeOut :: *;

import MemRegionAndAddressTranslate :: *;
import PayloadCon :: *;
import RecvStreamMocker :: *;
import Headers :: *;
import Ports :: *;
import StreamHandler :: *;

import XdmaWrapper :: *;
import UserLogicTypes :: *;
import RegisterBlock :: *;
import EthernetTypes :: *;


import Top :: *;

`define TEST_QPN_IDX_PART 'h3
`define TEST_QPN_KEY_PART 'h611

`define TEST_MR_IDX_PART 'h0
`define TEST_MR_KEY_PART 'h6622
`define TEST_MR_START_VA 'h0
`define TEST_MR_LENGTH   'h4000000
`define TEST_MR_FIRST_PGT_IDX   'h200

`define TEST_PGT_FIRST_ENTRY_PN 'h000C

`define TEST_PD_HANDLER   'h7890

`define TEST_WR_ADDR `TEST_MR_START_VA + 1
`define TEST_WR_LEN  1023


(* doc = "testcase" *)
module mkTestTop(Empty);

    ClockDividerIfc divClk <- mkClockDivider(2);
    Clock slowClock = divClk.slowClock;
    Reset slowReset <- mkInitialReset(1, clocked_by slowClock);
    Clock fastClock <- exposeCurrentClock;
    Reset fastReset <- exposeCurrentReset;

    Clock cmacRxTxClk <- mkAbsoluteClock(0, 15);
    // Clock cmacRxTxClk <- mkAbsoluteClock(0, 10);
    Reset cmacRxTxRst <- mkSyncReset(2, fastReset, cmacRxTxClk);

    RdmaUserLogicWithoutXdmaAndCmacWrapper topA <- mkRdmaUserLogicWithoutXdmaAndCmacWrapper(slowClock, slowReset);

    FakeXdma fakeXdmaA <- mkFakeXdma(1, cmacRxTxClk, cmacRxTxRst, clocked_by slowClock, reset_by slowReset);

    mkConnection(fakeXdmaA.xdmaH2cSrv, topA.dmaReadClt);
    mkConnection(fakeXdmaA.xdmaC2hSrv, topA.dmaWriteClt);

    SyncFIFOIfc#(CsrAddr) csrReadReqSyncFifo <- mkSyncFIFO(2, slowClock, slowReset, fastClock);
    mkConnection(fakeXdmaA.barReadClt.request, toPut(csrReadReqSyncFifo), clocked_by slowClock, reset_by slowReset); 

    SyncFIFOIfc#(CsrData) csrReadRespSyncFifo <- mkSyncFIFO(2, fastClock, fastReset, slowClock);
    mkConnection(toGet(csrReadRespSyncFifo), fakeXdmaA.barReadClt.response, clocked_by slowClock, reset_by slowReset); 

    SyncFIFOIfc#(Tuple2#(CsrAddr, CsrData)) csrWriteReqSyncFifo <- mkSyncFIFO(2, slowClock, slowReset, fastClock);
    mkConnection(fakeXdmaA.barWriteClt.request, toPut(csrWriteReqSyncFifo), clocked_by slowClock, reset_by slowReset); 

    SyncFIFOIfc#(Bool) csrWriteRespSyncFifo <- mkSyncFIFO(2, fastClock, fastReset, slowClock);
    mkConnection(toGet(csrWriteRespSyncFifo), fakeXdmaA.barWriteClt.response, clocked_by slowClock, reset_by slowReset); 

    // // loop tx stream to rx stream
    // rule displayAndForwardWireData;
    //     let d = topA.axiStreamTxOutUdp.first;
    //     topA.axiStreamTxOutUdp.deq;
    //     topA.axiStreamRxInUdp.put(d);
    //     $display("udp send data: ", fshow(d));
    // endrule


    // connect rx and tx to MockHost

    SyncFIFOIfc#(AxiStream512) netIfcRxSyncFifo <- mkSyncFIFO(32, cmacRxTxClk, cmacRxTxRst, fastClock);
    mkConnection(fakeXdmaA.axiStreamRxUdp, toPut(netIfcRxSyncFifo), clocked_by cmacRxTxClk, reset_by cmacRxTxRst);
    mkConnection(toGet(netIfcRxSyncFifo), topA.axiStreamRxInUdp);

    SyncFIFOIfc#(AxiStream512) netIfcTxSyncFifo <- mkSyncFIFO(32, fastClock, fastReset, cmacRxTxClk);
    // mkConnection(toGet(topA.axiStreamTxOutUdp), toPut(netIfcTxSyncFifo));
    rule forwardUdpSendStream;
        let txData = topA.axiStreamTxOutUdp.first;
        topA.axiStreamTxOutUdp.deq;
        netIfcTxSyncFifo.enq(txData);
        $display("time=%0t: ", $time, "forward udp send data to sync FIFO of CMAC");
    endrule
    mkConnection(convertSyncFifoToFifoOut(netIfcTxSyncFifo), fakeXdmaA.axiStreamTxUdp, clocked_by cmacRxTxClk, reset_by cmacRxTxRst); 


    rule forwardBarReadReq;
        csrReadReqSyncFifo.deq;
        let inReq = csrReadReqSyncFifo.first;
        let outReq = CsrReadRequest{addr: inReq};
        topA.csrReadSrv.request.put(outReq);
        // $display("csr read req =", fshow(outReq));
    endrule

    rule forwardBarReadResp;
        let inResp <- topA.csrReadSrv.response.get;
        let outResp = inResp.data;
        csrReadRespSyncFifo.enq(outResp);
        // $display("csr read resp =", fshow(outResp));
    endrule

    rule forwardBarWriteReq;
        csrWriteReqSyncFifo.deq;
        let inReq = csrWriteReqSyncFifo.first;
        let outReq = CsrWriteRequest{addr: tpl_1(inReq), data: tpl_2(inReq)};
        topA.csrWriteSrv.request.put(outReq);
        // $display("csr write req = ", fshow(outReq));
    endrule

    rule forwardBarWriteResp;
        let inResp <- topA.csrWriteSrv.response.get;
        let outResp = True;
        csrWriteRespSyncFifo.enq(outResp);
    endrule

    Reg#(Bool) stopReg <- mkReg(False);
    Reg#(UInt#(32)) idx <- mkReg(0);

endmodule


