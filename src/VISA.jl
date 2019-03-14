#=

Thin-veener over the VISA shared library.
See VPP-4.3.2 document for details.

=#
__precompile__(true)
module VISA
using Compat
using Libdl

# This package can prevent other packages from being tested on Travis CI because it
# expects a VISA library to be present and errors out when one is absent. The env variable
# VISA_JL_NO_LOAD may be set (to anything) to bypass the library dependency if you're okay
# with virtually everything in this package not working.
#
# Since the following lines are not in __init__(), they only get run during precompilation.
# The package must be recompiled to change this setting.
#
# tl;dr don't worry about it, things should work as before unless you set this env variable
!haskey(ENV, "VISA_JL_NO_LOAD") &&
    include(joinpath(@__DIR__,"..","deps","deps.jl"))

const defaultBufferSize = 0x00000400

############################ Types #############################################

#Vi datatypes
#Cribbed from VPP-4.3.2 section 3.1 table and/or visa.h
#It's most likely we don't actually need all of these but they're easy to
#generate with some metaprogramming

for typePair = [("UInt32", UInt32),
                ("Int32", Int32),
                ("UInt64", UInt64),
                ("Int64", Int64),
                ("UInt16", UInt16),
                ("Int16", Int16),
                ("UInt8", UInt8),
                ("Int8", Int8),
                ("Addr", Nothing),
                ("Char", Int8),
                ("Byte", UInt8),
                ("Boolean", UInt16),
                ("Real32", Float32),
                ("Real64", Float64),
                ("Status", Int32),
                ("Version", UInt32),
                ("Object", UInt32),
                ("Session", UInt32)
                ]

    viTypeName = Symbol("Vi"*typePair[1])
    viPTypeName = Symbol("ViP"*typePair[1])
    viATypeName = Symbol("ViA"*typePair[1])
    @eval begin
        const $viTypeName = $typePair[2]
        const $viPTypeName = Ptr{$viTypeName}
        const $viATypeName = Vector{$viTypeName}
        export $viTypeName, $viPTypeName, $viATypeName
    end
end

for typePair = [("Buf", "PByte"),
                ("String", "PChar"),
                ("Rsrc", "String")
                ]
    viTypeName = Symbol("Vi"*typePair[1])
    viPTypeName = Symbol("ViP"*typePair[1])
    viATypeName = Symbol("ViA"*typePair[1])

    mappedViType = Symbol("Vi"*typePair[2])

    @eval begin
        const $viTypeName = $mappedViType
        const $viPTypeName = $mappedViType
        const $viATypeName = Vector{$viTypeName}
        export $viTypeName, $viPTypeName, $viATypeName
    end
end

const ViEvent = ViObject
const ViPEvent = Ptr{ViEvent}
const ViFindList = ViObject
const ViPFindList = Ptr{ViFindList}
const ViString = ViPChar
const ViRsrc = ViString
const ViBuf = ViPByte;
const ViAccessMode = ViUInt32
const ViAttr = ViUInt32
const ViEventType = ViUInt32
const ViEventFilter = ViUInt32

export ViEvent, ViPEvent #soexclusive #VIP
export ViFindList, ViPFindList, ViString, ViRsrc, ViBuf, ViAccessMode
export ViAttr, ViEventType, ViEventFilter

########################## Constants ###########################################

# Completion and Error Codes ----------------------------------------------*/
include("codes.jl")

#Atributes and other definitions
include("constants.jl")

######################### Functions ############################################

export viOpenDefaultRM, viFindRsrc, viOpen, viClose
export viSetAttribute, viGetAttribute, viGetAttributeString
export viEnableEvent, viDisableEvent, viDiscardEvents, viWaitOnEvent
export viWrite, viRead!, viRead, viClear
export readAvailable, binBlockReadAvailable, binBlockWrite

#Helper macro to make VISA call and check the status for an error
macro check_status(viCall)
    return quote
        status = $(esc(viCall))
        if status < VI_SUCCESS
            errMsg = codes[status]
            error("VISA C call failed with status $(errMsg[1]): $(errMsg[2])")
        end
        status
    end
end

#- Resource Manager Functions and Operations -------------------------------#
function viOpenDefaultRM()
    rm = ViSession[0]
    @check_status ccall((:viOpenDefaultRM, libvisa), ViStatus, (ViPSession,), pointer(rm))
    rm[1]
end

function viFindRsrc(sesn::ViSession, expr::AbstractString)
    returnCount = ViUInt32[0]
    findList = ViFindList[0]
    desc = Array{ViChar}(VI_FIND_BUFLEN)
    @check_status ccall((:viFindRsrc, libvisa), ViStatus,
                        (ViSession, ViString, ViPFindList, ViPUInt32, ViPChar),
                        sesn, expr, findList, returnCount, desc)

    #Create the array of instrument strings and push them on
    instrStrs = ASCIIString[bytestring(convert(Ptr{UInt8}, pointer(desc)))]
    while (returnCount[1] > 1)
        @check_status ccall((:viFindNext, libvisa), ViStatus,
                        (ViFindList, ViPChar), findList[1], desc)
        returnCount[1] -= 1
        push!(instrStrs, bytestring(convert(Ptr{UInt8}, pointer(desc))))
    end

    instrStrs
end



# ViStatus _VI_FUNC  viParseRsrc     (ViSession rmSesn, ViRsrc rsrcName,
#                                     ViPUInt16 intfType, ViPUInt16 intfNum);
# ViStatus _VI_FUNC  viParseRsrcEx   (ViSession rmSesn, ViRsrc rsrcName, ViPUInt16 intfType,
#                                     ViPUInt16 intfNum, ViChar _VI_FAR rsrcClass[],
#                                     ViChar _VI_FAR expandedUnaliasedName[],
#                                     ViChar _VI_FAR aliasIfExists[]);


function viOpen(sesn::ViSession, name::AbstractString; mode::ViAccessMode=VI_NO_LOCK, timeout::ViUInt32=VI_TMO_IMMEDIATE)
    #Pointer for the instrument handle
    instrHandle = ViSession[0]
    @check_status ccall((:viOpen, libvisa), ViStatus,
                        (ViSession, ViRsrc, ViAccessMode, ViUInt32, ViPSession),
                        sesn, name, mode, timeout, instrHandle)
    instrHandle[1]
end

function viClose(viObj::ViObject)
    @check_status ccall((:viClose, libvisa), ViStatus, (ViObject,), viObj)
end




# #- Resource Template Operations --------------------------------------------*/

function viSetAttribute(viObj::ViObject, attrName::ViAttr, attrValue::ViAttrState)
    @check_status ccall((:viSetAttribute, libvisa), ViStatus,
                        (ViObject, ViAttr, ViAttrState),
                        viObj, attrName, attrValue)
end

function viGetAttribute(viObj::ViObject, attrName::ViAttr)
    value = ViAttrState[0]
    @check_status ccall((:viGetAttribute, libvisa), ViStatus,
                        (ViObject, ViAttr, Ptr{Nothing}),
                        viObj, attrName, value)
    value[]
end

function viGetAttributeString(viObj::ViObject, attrName::ViAttr)
    io = IOBuffer()
    write(io, viGetAttribute(viObj,attrName))
    seekstart(io)
    rstrip(readall(io),'\0')
end

# ViStatus _VI_FUNC  viStatusDesc    (ViObject vi, ViStatus status, ViChar _VI_FAR desc[]);
# ViStatus _VI_FUNC  viTerminate     (ViObject vi, ViUInt16 degree, ViJobId jobId);

# ViStatus _VI_FUNC  viLock          (ViSession vi, ViAccessMode lockType, ViUInt32 timeout,
#                                     ViKeyId requestedKey, ViChar _VI_FAR accessKey[]);
# ViStatus _VI_FUNC  viUnlock        (ViSession vi);

function viEnableEvent(instrHandle::ViSession, eventType::Integer,
                       mechanism::Integer)
    @check_status ccall((:viEnableEvent,libvisa), ViStatus,
                        (ViSession, ViEventType, UInt16, ViEventFilter),
                         instrHandle, eventType, mechanism, 0)
end

function viDisableEvent(instrHandle::ViSession, eventType::Integer,
                       mechanism::Integer)
    @check_status ccall((:viEnableEvent,libvisa), ViStatus,
                        (ViSession, ViEventType, UInt16),
                         instrHandle, eventType, mechanism)
end

function viDiscardEvents(instrHandle::ViSession, eventType::ViEventType,
                       mechanism::UInt16)
    @check_status ccall((:viEnableEvent,libvisa), ViStatus,
                        (ViSession, ViEventType, UInt16),
                         instrHandle, eventType, mechanism)
end

function viWaitOnEvent(instrHandle::ViSession, eventType::ViEventType, timeout::UInt32 = VI_TMO_INFINITE)
    outType = Array{ViEventType}()
    outEvent = Array{ViEvent}()
    @check_status ccall((:viWaitOnEvent,libvisa), ViStatus,
                        (ViSession, ViEventType, UInt32, Ptr{ViEventType}, Ptr{ViEvent}),
                         instrHandle, eventType, timeout, outType, outEvent)
    (outType[], outEvent[])
end

# ViStatus _VI_FUNC  viWaitOnEvent   (ViSession vi, ViEventType inEventType, ViUInt32 timeout,
#                                     ViPEventType outEventType, ViPEvent outContext);



# ViStatus _VI_FUNC  viDisableEvent  (ViSession vi, ViEventType eventType, ViUInt16 mechanism);
# ViStatus _VI_FUNC  viDiscardEvents (ViSession vi, ViEventType eventType, ViUInt16 mechanism);
# ViStatus _VI_FUNC  viWaitOnEvent   (ViSession vi, ViEventType inEventType, ViUInt32 timeout,
#                                     ViPEventType outEventType, ViPEvent outContext);
# ViStatus _VI_FUNC  viInstallHandler(ViSession vi, ViEventType eventType, ViHndlr handler,
#                                     ViAddr userHandle);
# ViStatus _VI_FUNC  viUninstallHandler(ViSession vi, ViEventType eventType, ViHndlr handler,
#                                       ViAddr userHandle);



#- Basic I/O Operations -------------------------------------------------------#

function viWrite(instrHandle::ViSession, message::AbstractString, terminator::AbstractString="")
    bytesWritten = ViUInt32[0]
    mess = message*terminator
    @check_status ccall((:viWrite, libvisa), ViStatus,
                        (ViSession, ViBuf, ViUInt32, ViPUInt32),
                        instrHandle, mess, length(mess), bytesWritten)
    bytesWritten[1]
end

function viWrite(instrHandle::ViSession, message::Vector{UInt8}, terminator::AbstractString="")
    bytesWritten = ViUInt32[0]
    io = IOBuffer()
    Base.write(io, terminator)
    seekstart(io)
    mess = [message; @compat take!(io)]
    @check_status ccall((:viWrite, libvisa), ViStatus,
                        (ViSession, ViBuf, ViUInt32, ViPUInt32),
                        instrHandle, mess, length(mess), bytesWritten)
    bytesWritten[1]
end

function viRead!(instrHandle::ViSession, buffer::Vector{UInt8})
    bytesRead = ViUInt32[0]
    status = @check_status ccall((:viRead, libvisa), ViStatus,
                        (ViSession, ViBuf, ViUInt32, ViPUInt32),
                        instrHandle, buffer, sizeof(buffer), bytesRead)
    return (status != VI_SUCCESS_MAX_CNT, bytesRead[])
end

function viRead(instrHandle::ViSession; bufSize::UInt32=defaultBufferSize)
    buf = Array{UInt8}(bufSize)
    (done, bytesRead) = viRead!(instrHandle, buf)
    buf[1:bytesRead]
end

# ViStatus _VI_FUNC  viReadAsync     (ViSession vi, ViPBuf buf, ViUInt32 cnt, ViPJobId  jobId);
# ViStatus _VI_FUNC  viReadToFile    (ViSession vi, ViConstString filename, ViUInt32 cnt,
#                                     ViPUInt32 retCnt);
# ViStatus _VI_FUNC  viWriteAsync    (ViSession vi, ViBuf  buf, ViUInt32 cnt, ViPJobId  jobId);
# ViStatus _VI_FUNC  viWriteFromFile (ViSession vi, ViConstString filename, ViUInt32 cnt,
#                                     ViPUInt32 retCnt);
# ViStatus _VI_FUNC  viAssertTrigger (ViSession vi, ViUInt16 protocol);
# ViStatus _VI_FUNC  viReadSTB       (ViSession vi, ViPUInt16 status);
# ViStatus _VI_FUNC  viClear         (ViSession vi);

function viClear(instrHandle::ViSession)
    @check_status ccall((:viClear, libvisa), ViStatus, (ViSession,), instrHandle)
end

#- Outside the specification --------------------------------------------------#

function readAvailable(instrHandle::ViSession)
    ret = IOBuffer()
    buf = Array{UInt8}(defaultBufferSize)
    while true
        (done, bytesRead) = viRead!(instrHandle, buf)
        write(ret,buf[1:bytesRead])
        if done
            break
        end
    end
    @compat take!(ret)
end

# At the moment, terminators are not included in the digit count...
function binBlockWrite(instrHandle::ViSession, message::Union{AbstractString, Vector{UInt8}}, data::Vector{UInt8}, terminator::AbstractString="")
    len = length(data)
    dig = ndigits(len,10)
    @assert dig <= 9 "Data too long."
    header = [UInt8(x) for x in string("#",dig,len)]
    viWrite(instrHandle,[convert(Array{UInt8,1},message);header;data]::Array{UInt8,1}, terminator)
end

function binBlockReadAvailable(instrHandle::ViSession)
    ret = IOBuffer()
    buf = Array{UInt8}(defaultBufferSize)

    (done, bytesRead) = viRead!(instrHandle, buf)
    write(ret, buf[1:bytesRead])

    dataLength = parseIEEEBlockHeader(ret)

    totalLengthToRead = ret.ptr + dataLength
    offset = ret.ptr
    seekend(ret)

    while (bytesRead < totalLengthToRead)
        (done, bytes) = viRead!(instrHandle, buf)
        write(ret,buf[1:bytes])
        bytesRead += bytes
    end

    if (!done)
        error("Read the expected number of bytes, but not done reading.")
    end

    seek(ret,offset-1)
    ret # You can get the number of bytes to parse without using the header: ret.size-ret.ptr
end

"""
Takes an IOBuffer, seeks the start, and reads through the header, returning the
data length (excluding header). The buffer pointer is left at the start of The
data (excluding header). Does not support the `#0...` header.
"""
function parseIEEEBlockHeader(io::IOBuffer)
    seekstart(io)

    if (read(io,Char) != '#')
        error("Not an IEEE block header")
    end

    dig = parse(Compat.String(copy(read(io,UInt8,1))))
    if (dig != 0)
        dataLength = parse(Compat.String(copy(read(io,UInt8,dig))))
    else
        error("Unknown bytes expected.")
    end

    return dataLength
end

end
