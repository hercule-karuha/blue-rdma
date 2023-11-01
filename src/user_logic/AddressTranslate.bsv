import Arbitration :: *;
import BRAM :: *;
import ClientServer :: *;
import Cntrs :: *;
import Connectable :: *;
import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import Utils :: *;
import UserLogicTypes :: *;


typedef Server#(addrType, dataType) BramRead#(type addrType, type dataType);

interface BramCache#(type addrType, type dataType);
    interface BramRead#(addrType, dataType) read;
    method Action write(addrType cacheAddr, dataType writeData);
endinterface


module mkBramCache(BramCache#(addrType, dataType)) provisos(Bits#(addrType, addrTypeSize), Bits#(dataType, dataTypeSize));
    BRAM_Configure cfg = defaultValue;
    // Both read address and read output are registered
    cfg.latency = 2;
    // Allow full pipeline behavior
    cfg.outFIFODepth = 4;
    BRAM2Port#(addrType, dataType) bram2Port <- mkBRAM2Server(cfg);

    FIFOF#(addrType)  bramReadReqQ <- mkFIFOF;
    FIFOF#(dataType) bramReadRespQ <- mkFIFOF;

    rule handleBramReadReq;
        let cacheAddr = bramReadReqQ.first;
        bramReadReqQ.deq;

        let req = BRAMRequest{
            write: False,
            responseOnWrite: False,
            address: cacheAddr,
            datain: dontCareValue
        };
        bram2Port.portA.request.put(req);
    endrule

    rule handleBramReadResp;
        let readRespData <- bram2Port.portA.response.get;
        bramReadRespQ.enq(readRespData);
    endrule

    method Action write(addrType cacheAddr, dataType writeData);
        let req = BRAMRequest{
            write: True,
            responseOnWrite: False,
            address: cacheAddr,
            datain: writeData
        };
        bram2Port.portB.request.put(req);
    endmethod

    interface read = toGPServer(bramReadReqQ, bramReadRespQ);
endmodule


typedef Tuple2#(ASID, ADDR) FindReqTLB;
typedef Tuple2#(Bool, ADDR) FindRespTLB;
typedef Server#(FindReqTLB, FindRespTLB) FindInTLB;

interface TLB;
    interface FindInTLB find;
    method Action modify(PgtModifyReq req);
endinterface

function Bit#(PAGE_OFFSET_WIDTH) getPageOffset(ADDR addr);
    return truncate(addr);
endfunction

function ADDR restorePA(
    Bit#(TLB_CACHE_PA_DATA_WIDTH) paData, Bit#(PAGE_OFFSET_WIDTH) pageOffset
);
    return signExtend({ paData, pageOffset });
endfunction

function Bit#(TLB_CACHE_PA_DATA_WIDTH) getData4PA(ADDR pa);
    return truncate(pa >> valueOf(PAGE_OFFSET_WIDTH));
endfunction

function ADDR getPageAlignedAddr(ADDR addr);
    Bit#(TLog#(PAGE_SIZE_CAP)) t = 0;
    addr[valueOf(TLog#(PAGE_SIZE_CAP))-1:0] = t;
    return unpack(addr);
endfunction


module mkTLB(TLB);
    BramCache#(PgtFirstStageIndex, PgtFirstStagePayload) firstStageCache <- mkBramCache;
    BramCache#(PgtSecondStageIndex, PgtSecondStagePayload) secondStageCache <- mkBramCache;


    FIFOF#(ADDR) vaInputQ <- mkFIFOF;
    FIFOF#(Maybe#(Bit#(PAGE_OFFSET_WIDTH))) offsetInputQ <- mkFIFOF;
    FIFOF#(FindReqTLB) findReqQ <- mkFIFOF;
    FIFOF#(FindRespTLB) findRespQ <- mkFIFOF;

    rule handleFindReq;
        let req = findReqQ.first;
        findReqQ.deq;
        firstStageCache.read.request.put(tpl_1(req));
        vaInputQ.enq(tpl_2(req));
    endrule

    rule handleSecondStageQuery;
        let va = vaInputQ.first;
        vaInputQ.deq;

        PgtFirstStagePayload firstStageResp <- firstStageCache.read.response.get;

        let vaOffset = va - firstStageResp.baseVA;
        let secondStageIndexOffset = truncate(vaOffset >> valueOf(PAGE_OFFSET_WIDTH));

        PgtSecondStageIndex secondStageIndex = firstStageResp.secondStageOffset + secondStageIndexOffset;
        let addrToRead = secondStageIndex;
        secondStageCache.read.request.put(addrToRead);

        let pageOffset = getPageOffset(va);

        let pteValid = firstStageResp.secondStageEntryCnt != 0;

        offsetInputQ.enq(pteValid ? tagged Valid pageOffset : tagged Invalid);
    endrule

    rule handleFindResp;
        let pageOffset = offsetInputQ.first;
        offsetInputQ.deq;

        PgtSecondStagePayload secondStageResp <- secondStageCache.read.response.get;

        if (pageOffset matches tagged Valid .offset) begin
            let pa = restorePA(secondStageResp.paPart, offset);
            findRespQ.enq(tuple2(True, pa));
        end else begin
            findRespQ.enq(tuple2(False, ?));
        end
        
        
    endrule

    method Action modify(PgtModifyReq req);
        case (req) matches
            tagged Req4FirstStage .r: begin
                firstStageCache.write(
                    r.asid,
                    r.content
                );
            end
            tagged Req4SecondStage .r: begin
                secondStageCache.write(
                    r.index,
                    r.content
                );
            end
        endcase
    endmethod

    interface find = toGPServer(findReqQ, findRespQ);
endmodule



interface PgtManager;
    interface Server#(DmaFetchedCmd, RdmaCmdExecuteResponse) pgtModifySrv;
endinterface


typedef enum {
    PgtManagerFsmStateIdle,
    PgtManagerFsmStateHandleFirstStageUpdate,
    PgtManagerFsmStateHandleSecondStageUpdate
} PgtManagerFsmState deriving(Bits, Eq);


module mkPgtManager#(TLB tlb)(PgtManager);
    FIFOF#(DmaFetchedCmd) reqQ <- mkFIFOF;
    FIFOF#(RdmaCmdExecuteResponse) respQ <- mkFIFOF;



    Reg#(PgtManagerFsmState) state <- mkReg(PgtManagerFsmStateIdle);

    Reg#(DataStream) curBeatOfData <- mkRegU;
    Reg#(ControlCmdReqId) curReqId <- mkRegU;
    
    Integer bytesPerPgtSecondStageEntryRequest = valueOf(PGT_SECOND_STAGE_ENTRY_REQUEST_SIZE_PADDED) / valueOf(BYTE_WIDTH);

    rule updatePgtStateIdle if (state == PgtManagerFsmStateIdle);
        reqQ.deq;
        let req = reqQ.first;
        
        immAssert(
            req.dataStream.isFirst,
            "req.dataStream.isFirst must be True @ mkPgtManager",
            $format(
                "req=", fshow(req), " should be valid"
            )
        );
        curBeatOfData <= req.dataStream;
        curReqId <= req.reqId;
        if (req.cmdType == RdmaCsrCmdTypeModifyFirstStagePgt) begin
            state <= PgtManagerFsmStateIdle;
            PgtModifyFirstStageReq modifyReq = unpack(truncate(req.dataStream.data));
            tlb.modify(tagged Req4FirstStage modifyReq);
            respQ.enq(RdmaCmdExecuteResponse{
                finishedReqId: req.reqId,
                errorCode: 0
            });
        end else begin 
            state <= PgtManagerFsmStateHandleSecondStageUpdate;
        end
    endrule

    rule updatePgtStateHandleSecondStageUpdate if (state == PgtManagerFsmStateHandleSecondStageUpdate);
        
        PgtModifySecondStageReq modifyReq = unpack(truncate(curBeatOfData.data));
        tlb.modify(tagged Req4SecondStage modifyReq);
        
        let newCurBeatOfData = curBeatOfData;
        newCurBeatOfData.byteEn = newCurBeatOfData.byteEn >> bytesPerPgtSecondStageEntryRequest;
        newCurBeatOfData.data = newCurBeatOfData.data >> (bytesPerPgtSecondStageEntryRequest * valueOf(BYTE_WIDTH));

        if (newCurBeatOfData.byteEn[0] == 0) begin 
            if (curBeatOfData.isLast) begin
                state <= PgtManagerFsmStateIdle;
                respQ.enq(RdmaCmdExecuteResponse{
                    finishedReqId: curReqId,
                    errorCode: 0
                });
            end else if (reqQ.notEmpty) begin
                reqQ.deq;
                curBeatOfData <= reqQ.first.dataStream;
            end
        end else begin
            curBeatOfData <= newCurBeatOfData;
        end
    endrule

    interface pgtModifySrv = toGPServer(reqQ, respQ);
endmodule