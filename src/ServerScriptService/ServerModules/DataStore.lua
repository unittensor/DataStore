local type=type
local error=error
local pcall=pcall
local select=select
local unpack=unpack
local tostring=tostring

local band=bit32.band

local coyield=coroutine.yield
local cocreate=coroutine.create
local coresume=coroutine.resume
local corunning=coroutine.running

local ReplicatedStorage=game:GetService'ReplicatedStorage'

local RingBufferClass=require(ReplicatedStorage.SharedModules.RingBuffer)

local DataStoreService=game:GetService'DataStore'

--[[per key limit
Property 	Size Limit
Name 		50
Scope 		50
Key 		50
Data* 		4194303
--]]

--[[ backlog limit
/ Budget Type 				Start 	Base rate 	Per-player rate 	N Player Max (for N >= 0)
GetAsync 					100 	60 			40 					3 * (60 + N * 40)
{Set|Increment}Async 		100 	60 			40 					3 * (60 + N * 40)
GetSortedAsync 				10 		5 			2 					3 * (5 + N * 2)
{Set|Increment}SortedAsync	100 	30 			5 					3 * (30 + N * 5)
OnUpdate 					30 		30 			5 					1 * (30 + N * 5)
UpdateAsync 				100 	60 			40 					3 * (60 + N * 40)
--]]

local REQUEST_GUARANTEE_ORDER=1
local REQUEST_GUARANTEE_DELIVERY=2

local RequestFlags={
	REQUEST_GUARANTEE_ORDER=REQUEST_GUARANTEE_ORDER,
	REQUEST_GUARANTEE_DELIVERY=REQUEST_GUARANTEE_DELIVERY,
}

--DataStoreRequestType
--This list informs how many independently ratelimited request lanes there are
local RequestTypes={
--Normal queries
	"GetAsync",
	"SetIncrementAsync",
	"UpdateAsync", -- note: read counts towards GetAsync budget, write counts towards SetIncrementAsync budget
	"GetSortedAsync",
	"SetIncrementSortedAsync",
	"OnUpdate", -- "OnUpdate only consumes budget when you connect it, not when triggered" ok
--Special queries (not implemented)
--	"ListAsync",
--	"GetVersionAsync",
--	"RemoveVersionAsync",
}
local NRequestTypes=#RequestTypes
local RequestTypeIdFromRequestType={}
for i=1,NRequestTypes do
	RequestTypeIdFromRequestType[RequestTypes[i]]=i
end
local RequestTypeEnumFromRequestType={}
for i=1,NRequestTypes do
	local RequestType=RequestTypes[i]
	RequestTypeEnumFromRequestType[RequestType]=Enum.RequestType[RequestType]
end

--DataStore:GetRequestBudgetForRequestType
--guaranteed delivery requests are sent to a specific lane that checks the current budget and works through the queue
local RequestTypeIdFromFunctionName={
	GetAsync=				1,--GetAsync
	SetAsync=				2,--SetIncrementAsync
	IncrementAsync=			2,--SetIncrementAsync
	UpdateAsync=			3,--UpdateAsync
	GetSortedAsync=			4,--GetSortedAsync
	SetSortedAsync=			5,--SetIncrementSortedAsync
	IncrementSortedAsync=	5,--SetIncrementSortedAsync
	OnUpdate=				6,--OnUpdate
--	ListAsync=				7,--ListAsync
--	GetVersionAsync=		8,--GetVersionAsync
--	RemoveVersionAsync=		9,--RemoveVersionAsync
}
local RequestTypeEnumFromFunctionName={
	GetAsync=				Enum.DataStoreRequestType.GetAsync,
	SetAsync=				Enum.DataStoreRequestType.SetIncrementAsync,
	IncrementAsync=			Enum.DataStoreRequestType.SetIncrementAsync,
	UpdateAsync=			Enum.DataStoreRequestType.UpdateAsync,
	GetSortedAsync=			Enum.DataStoreRequestType.GetSortedAsync,
	SetSortedAsync=			Enum.DataStoreRequestType.SetIncrementSortedAsync,
	IncrementSortedAsync=	Enum.DataStoreRequestType.SetIncrementSortedAsync,
	OnUpdate=				Enum.DataStoreRequestType.OnUpdate,
--	ListAsync=				Enum.DataStoreRequestType.ListAsync,
--	GetVersionAsync=		Enum.DataStoreRequestType.GetVersionAsync,
--	RemoveVersionAsync=		Enum.DataStoreRequestType.RemoveVersionAsync,
}

--convert to and 
local RequestFunctionNames={
	"GetAsync",
	"SetAsync",
	"IncrementAsync",
	"UpdateAsync",
	"GetSortedAsync",
	"SetSortedAsync",
	"IncrementSortedAsync",
	"OnUpdate",
--	"ListAsync",
--	"GetVersionAsync",
--	"RemoveVersionAsync",
}
local FunctionIdFromFunctionName={}
for i=1,#RequestFunctionNames do
	FunctionIdFromFunctionName[RequestFunctionNames[i]]=i
end

--guarantee order means that the request is processed through a global queue in a specific lane
--guarantee delivery means that the request will retry indefinitely, otherwise it will try once and return an error.

--If a request asks for guaranteed order, it will be placed at the back of the global queue even if guaranteed delivery is not flagged

local global_ordered_request_queue=RingBufferClass()
local delivery_request_queue_lanes={}
for i=1,NRequestTypes do
	delivery_request_queue_lanes[i]=RingBufferClass()
end

local function resumePrintErr(...)
	local NoErr,ErrMsg=coresume(...)
	if not NoErr then
		print("error:",ErrMsg)
	end
end

local function GetLane(request)
	local flags=request.Flags
	if band(flags,REQUEST_GUARANTEE_ORDER)~=0 then
		return global_ordered_request_queue
	elseif band(flags,REQUEST_GUARANTEE_DELIVERY)~=0 then
		--request.FunctionName is supposed to be validated at this point
		return delivery_request_queue_lanes[RequestTypeIdFromFunctionName[request.FunctionName]]
	end
	--requests with empty flags are attempted immediately and then dropped, no lane interaction
	return nil
end

--returns inline_success,status,result
local function DoRequest(attempt_inline,request)
	local data_store=DataStoreService:GetDataStore(request.StoreName,request.StoreScope)
	local status,result=pcall(data_store[request.FunctionName],data_store,unpack(request.Args,request.NArgs))
	if not status then
		print("DataStore request failed:",request.StoreName,request.StoreScope,request.FunctionName)
		print("Error:",result)
		--if REQUEST_GUARANTEE_DELIVERY bit is set, push the request into a lane
		if band(request.Flags,REQUEST_GUARANTEE_DELIVERY)~=0 then
			local lane=GetLane(request)
			if lane then
				lane:PushBack(request)
				--inline failed, request must be delayed
				return false
			else
				--this is an error because requests with REQUEST_GUARANTEE_DELIVERY should always return a lane
				error("Could not get lane for request")
			end
		end
	end
	local Thread=request.Thread
	if Thread then
		resumePrintErr(Thread,status,unpack(result))
	else
		return attempt_inline,status,result
	end
end

--returns inline_success,status,result
local function RunDoRequest(attempt_inline,request)
	if attempt_inline then
		return DoRequest(attempt_inline,request)
	else
		resumePrintErr(cocreate(DoRequest),attempt_inline,request)
		return false
	end
end

--returns inline_success,status,result
local function ProcessRequest(attempt_inline,request)
	--if lane is empty, try immediately
	local lane=GetLane(request)
	if lane then
		--if there is no requests ahead of this one, try it immediately
		if lane:GetLength()==0 then
			if 0<DataStoreService:GetRequestBudgetForRequestType(RequestTypeEnumFromFunctionName[request.FunctionName]) then
				return RunDoRequest(attempt_inline,request)
			else
				return false
			end
		else
			lane:PushBack(request)
			return false
		end
	else
		return RunDoRequest(attempt_inline,request)
	end
end

local function ValidateRequest(store_name,store_scope,request_fn_name,request_flags)
	if type(store_name)~="string" then
		error("Expected string for 'store_name', found "..type(store_name))
	end
	if type(store_scope)~="string" then
		error("Expected string for 'store_scope', found "..type(store_scope))
	end
	if type(request_fn_name)~="string" then
		error("Expected string for 'request_fn_name', found "..type(request_fn_name))
	end
	if not FunctionIdFromFunctionName[request_fn_name] then
		error("Invalid request_fn_name: "..tostring(request_fn_name))
	end
	if type(request_flags)~="number" then
		error("Expected number for 'request_flags', found "..type(request_flags))
	end
end

local function BlockingRequest(store_name,store_scope,request_fn_name,request_flags,...)
	ValidateRequest(store_name,store_scope,request_fn_name,request_flags)
	local request={
		StoreName=store_name,
		StoreScope=store_scope,
		FunctionName=request_fn_name,
		Flags=request_flags,
		Args={...},
		NArgs=select("#",...),
	}
	local inline_success,status,result=ProcessRequest(true,request)
	if inline_success then
		return status,unpack(result)
	else
		request.Thread=corunning()
		return coyield()
	end
end

local function CallbackRequest(callback,store_name,store_scope,request_fn_name,request_flags,...)
	ValidateRequest(store_name,store_scope,request_fn_name,request_flags)
	local request={
		StoreName=store_name,
		StoreScope=store_scope,
		FunctionName=request_fn_name,
		Flags=request_flags,
		Args={...},
		NArgs=select("#",...),
	}
	local Thread=cocreate(callback)
	local inline_success,status,result=ProcessRequest(false,request)
	if inline_success then
		--unreachable
		resumePrintErr(Thread,status,unpack(result))
	else
		request.Thread=Thread
	end
end

local function ProcessLane(lane)
	while true do
		local front_request=lane:PeekFront()
		if front_request then
			local RequestFunctionName=front_request.FunctionName
			if 0<DataStoreService:GetRequestBudgetForRequestType(RequestTypeEnumFromFunctionName[RequestFunctionName]) then
				RunDoRequest(false,lane:PopFront())
			else
				break
			end
		else
			break
		end
	end
end

game:GetService'RunService'.Stepped:connect(function()
	--check global_ordered_request_queue
	ProcessLane(global_ordered_request_queue)
	--check delivery_request_queue_lanes
	for lane=1,NRequestTypes do
		ProcessLane(delivery_request_queue_lanes[lane])
	end
end)

return {
	RequestFlags=RequestFlags,
	BlockingRequest=BlockingRequest,
	CallbackRequest=CallbackRequest,
}
