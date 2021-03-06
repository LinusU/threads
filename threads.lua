local Queue = require 'threads.queue'
local clib = require 'libthreads'
local unpack = unpack or table.unpack

local Threads = {}
local Threads_ctor = {}
setmetatable(
   Threads_ctor, {
      __newindex = Threads,
      __index = Threads,
      __call =
         function(self, ...)
            return Threads.new(...)
         end
   }
)

Threads.__index = Threads
Threads.__serialize = "threads.serialize"

-- GC: lua 5.2
Threads.__gc =
   function(self)
      self:terminate()
   end

function Threads.serialization(name)
   if name then
      assert(type(name) == 'string')
      Threads.__serialize = name
   else
      return Threads.__serialize
   end
end

function Threads.new(N, ...)
   local self = {N=N, endcallbacks={n=0}, errors={}, __specific=true, __running=true}
   local funcs = {...}
   local serialize = require(Threads.__serialize)

   if #funcs == 0 then
      funcs = {function() end}
   end

   setmetatable(self, Threads)

   self.mainqueue = Queue(N, Threads.__serialize)
   self.threadqueue = Queue(N, Threads.__serialize)
   self.threadspecificqueues = {}
   self.mainqueue:retain() -- terminate will free it
   self.threadqueue:retain() -- terminate will free it

   self.threads = {}
   for i=1,N do
      self.threadspecificqueues[i] = Queue(N, Threads.__serialize)
      self.threadspecificqueues[i]:retain() -- terminate will free it

      local thread = clib.Thread(
         string.format(
            [[
  local Queue = require 'threads.queue'
  __threadid = %d
  local mainqueue = Queue(%d)
  local threadqueue = Queue(%d)
  local threadspecificqueue = Queue(%d)
  local threadid = __threadid

  __queue_running = true
  __queue_specific = true
  while __queue_running do
     local status, res, endcallbackid
     if __queue_specific then
       status, res, endcallbackid = threadspecificqueue:dojob()
     else
       status, res, endcallbackid = threadqueue:dojob()
     end
     mainqueue:addjob(function()
                          return status, res, endcallbackid, threadid
                       end)
  end
]],
            i,
            self.mainqueue:id(),
            self.threadqueue:id(),
            self.threadspecificqueues[i]:id()
         ))

      assert(thread, string.format('%d-th thread creation failed', i))

      table.insert(self.threads, thread)
   end

   -- GC: lua 5.1
   if newproxy then
      self.__gc__ = newproxy(true)
      getmetatable(self.__gc__).__gc =
         function()
            self:terminate() -- all the queues must be alive (hence the retains above)
         end
   end

   local initres = {}
   for j=1,#funcs do
      for i=1,self.N do
         if j ~= #funcs then
            self:addjob(
               i, -- specific
               funcs[j],
               function()
               end,
               i -- passed to callback
            )
         else
            self:addjob(
               i, -- specific
               funcs[j],
               function(...)
                  table.insert(initres, {...})
               end,
               i -- passed to callback
            )
         end
      end
   end
   self:specific(false)

   return self, initres
end

function Threads:isrunning()
   return self.__running
end

local function checkrunning(self)
   assert(self:isrunning(), 'thread system is not running')
end

function Threads:specific(flag)
   checkrunning(self)
   if flag ~= nil then
      assert(type(flag) == 'boolean', 'boolean expected')
      self:synchronize() -- finish jobs first
      if self.__specific ~= flag then
         if self.__specific then
            for i=1,self.N do
               self:addjob(i,
                           function()
                              __queue_specific = false
                           end)
            end
         else
            for i=1,self.N do
               self:addjob(function()
                              __queue_specific = true
                           end)
            end
         end
         self.__specific = flag
         self:synchronize() -- finish jobs
      end
   else
      return self.__specific
   end
end

function Threads:dojob()
   checkrunning(self)
   local endcallbacks = self.endcallbacks
   local callstatus, args, endcallbackid, threadid = self.mainqueue:dojob()
   if callstatus then
      local endcallstatus, msg = pcall(endcallbacks[endcallbackid], unpack(args))
      if not endcallstatus then
         table.insert(self.errors, string.format('[thread %d endcallback] %s', threadid, msg))
      end
   else
      table.insert(self.errors, string.format('[thread %d callback] %s', threadid, args[1]))
   end
   endcallbacks[endcallbackid] = nil
   endcallbacks.n = endcallbacks.n - 1
end

function Threads:acceptsjob(idx)
   checkrunning(self)
   local threadqueue
   if self:specific() then
      assert(type(idx) == 'number' and idx >= 1 and idx <= self.N, 'thread index expected')
      threadqueue = self.threadspecificqueues[idx]
   else
      threadqueue = self.threadqueue
   end
   return threadqueue.isfull ~= 1
end

function Threads:addjob(...) -- endcallback is passed with returned values of callback
   checkrunning(self)
   if #self.errors > 0 then self:synchronize() end -- if errors exist, sync immediately.
   local endcallbacks = self.endcallbacks

   local idx, threadqueue, r, callback, endcallback
   if self:specific() then
      idx = select(1, ...)
      assert(type(idx) == 'number' and idx >= 1 and idx <= self.N, 'thread index expected')
      threadqueue = self.threadspecificqueues[idx]
      callback = select(2, ...)
      endcallback = select(3, ...)
      r = 4
   else
      callback = select(1, ...)
      endcallback = select(2, ...)
      threadqueue = self.threadqueue
      r = 3
   end
   assert(type(callback) == 'function', 'function callback expected')
   assert(type(endcallback) == 'function' or type(endcallback) == 'nil', 'function (or nil) endcallback expected')

   -- finish running jobs if no space available
   while not self:acceptsjob(idx) do
      self:dojob()
   end

   -- now add a new endcallback in the list
   local endcallbackid = #endcallbacks+1
   endcallbacks[endcallbackid] = endcallback or function() end
   endcallbacks.n = endcallbacks.n + 1

   local func = function(...)
      local res = {pcall(callback, ...)}
      local status = table.remove(res, 1)
      return status, res, endcallbackid
   end

   threadqueue:addjob(func, select(r, ...))
end

function Threads:haserror()
   checkrunning(self)
   return (#self.errors > 0)
end

function Threads:hasjob()
   checkrunning(self)
   return self.endcallbacks.n > 0
end

function Threads:synchronize()
   if not self:isrunning() then
      return
   end
   while self:hasjob()do
      self:dojob()
   end
   if self:haserror() then
      local msg = string.format('\n%s', table.concat(self.errors, '\n'))
      self.errors = {}
      error(msg)
   end
end

function Threads:terminate()
   if not self:isrunning() then
      return
   end

   -- terminate the threads
   for i=1,self.N do
      if self:specific() then
         self:addjob(
            i,
            function()
               __queue_running = false
            end)
      else
         self:addjob(
            function()
               __queue_running = false
            end)
      end
   end

   -- terminate all jobs
   self:synchronize()

   -- wait for threads to exit (and free them)
   for i=1,self.N do
      self.threads[i]:free()
   end

   -- release the queues
   self.mainqueue:free()
   self.threadqueue:free()
   for i=1,self.N do
      self.threadspecificqueues[i]:free()
   end

   -- make sure you won't run anything
   self.__running = false
end

return Threads_ctor
