--!optimize 2
--!strict

--Generic object class constructor class
local setmetatable=setmetatable

local clone=table.clone

type ClassConstructor = typeof(setmetatable({} :: Constructor_Return_Props, {} :: Impl_Constructor))

type MetamethodFunc = <T>(T) -> T
type Impl_Constructor = {
	__newindex: <T>(self: ClassConstructor, Name: string, f: MetamethodFunc) -> ();
	__call: <T...>(self: ClassConstructor, T...) -> ();
}

type Array<K,V> = {[K]: V}
type Metamethods = Array<string, MetamethodFunc>
type Base = {Metamethods: Metamethods}

type InstanceConstructor = typeof(setmetatable({}, {} :: {__index: Metamethods}))

type Constructor_Return_Props = {
	Base: Base;
	Constructor: <T...>(T...) -> T...;
	Metatable: {__index: Metamethods};
	Metamethods: Metamethods;
}

local Metatable={} :: Impl_Constructor

local function SetMetamethod<T>(self: ClassConstructor, Name: string, f: MetamethodFunc): ()
	self.Metamethods[Name]=f
end
Metatable.__newindex=SetMetamethod

local function DepthFirstConstructor<T,U...>(self: ClassConstructor, Instance: T, ...: U...): ()
	if self.Base then
		--There is nothing i can do about this type error without rewriting the function
		--Remove the "any" type cast from "self.Base" to unsilence the error
		DepthFirstConstructor(self.Base :: any, Instance,...)
	end
	self.Constructor(Instance,...)
end

local function Call<T...>(self: ClassConstructor, ...: T...): InstanceConstructor
	local Instance=setmetatable({},self.Metatable)
	DepthFirstConstructor(self,Instance,...)
	return Instance
end
Metatable.__call=Call

local function Thru<T...>(...: T...): T...
	return ...
end

local function New(Base: Base?): ClassConstructor
	local Metamethods
	if Base then
		Metamethods=clone(Base.Metamethods)
	else
		Metamethods={}
	end
	return setmetatable({
		Base=Base :: Base,
		Constructor=Thru,
		Metatable={__index=Metamethods},
		Metamethods=Metamethods,
	},Metatable)
end

export type Class = ClassConstructor
return New