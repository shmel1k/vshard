test_run = require('test_run').new()
REPLICASET_1 = { 'storage_1_a', 'storage_1_b' }
REPLICASET_2 = { 'storage_2_a', 'storage_2_b' }
test_run:create_cluster(REPLICASET_1, 'router')
test_run:create_cluster(REPLICASET_2, 'router')
util = require('util')
util.wait_master(test_run, REPLICASET_1, 'storage_1_a')
util.wait_master(test_run, REPLICASET_2, 'storage_2_a')
util.map_evals(test_run, {REPLICASET_1, REPLICASET_2}, 'bootstrap_storage(\'memtx\')')
util.push_rs_filters(test_run)
_ = test_run:cmd("create server router_1 with script='router/router_1.lua'")
_ = test_run:cmd("start server router_1")

_ = test_run:switch("router_1")
-- gh-46: Ensure a cfg is not destroyed after router.cfg().
cfg.sharding ~= nil

util = require('util')

-- gh-24: log all connnect/disconnect events.
test_run:grep_log('router_1', 'connected to ')
rs1 = vshard.router.static.replicasets[util.replicasets[1]]
rs2 = vshard.router.static.replicasets[util.replicasets[2]]
fiber = require('fiber')
while not rs1.replica or not rs2.replica do fiber.sleep(0.1) end
-- With no zones the nearest server is master.
rs1.replica == rs1.master
rs2.replica == rs2.master

--
-- Part of gh-76: on reconfiguration do not recreate connections
-- to replicas, that are kept in a new configuration.
--
old_replicasets = vshard.router.static.replicasets
old_connections = {}
connection_count = 0
_ = test_run:cmd("setopt delimiter ';'")
for _, old_rs in pairs(old_replicasets) do
    for uuid, old_replica in pairs(old_rs.replicas) do
        old_connections[uuid] = old_replica.conn
        connection_count = connection_count + 1
    end
end;
_ = test_run:cmd("setopt delimiter ''");
connection_count == 4
vshard.router.cfg(cfg)
new_replicasets = vshard.router.static.replicasets
old_replicasets ~= new_replicasets
rs1 = vshard.router.static.replicasets[util.replicasets[1]]
rs2 = vshard.router.static.replicasets[util.replicasets[2]]
while not rs1.replica or not rs2.replica do fiber.sleep(0.1) end
vshard.router.discovery_wakeup()
-- Check that netbox connections are the same.
_ = test_run:cmd("setopt delimiter ';'")
for _, new_rs in pairs(new_replicasets) do
    for uuid, new_replica in pairs(new_rs.replicas) do
        assert(old_connections[uuid] == new_replica.conn)
    end
end;
_ = test_run:cmd("setopt delimiter ''");

--
-- bucket_id and bucket_count
--

util.check_error(vshard.router.bucket_id) -- invalid arguments
vshard.router.bucket_id(1)
vshard.router.bucket_id(2)
vshard.router.bucket_id({2})
vshard.router.bucket_id('2')
vshard.router.bucket_count()

--
-- Initial distribution
--
util.check_error(vshard.router.call, 1, 'read', 'echo', {123})
replicaset, err = vshard.router.bucket_discovery(1); return err == nil or err
vshard.router.bootstrap({timeout = 5})

-- Second one should produce error
vshard.router.bootstrap()

--
-- gh-108: negative bucket count on discovery.
--
vshard.router.static.route_map = {}
rets = {}
function do_echo() table.insert(rets, vshard.router.callro(1, 'echo', {1})) end
f1 = fiber.create(do_echo) f2 = fiber.create(do_echo)
while f1:status() ~= 'dead' and f2:status() ~= 'dead' do fiber.sleep(0.01) end
vshard.router.info()
rets
rs1.bucket_count
rs2.bucket_count

--
-- Negative bucket count appeared again once router cfg got route
-- map keeping on recfg.
--
vshard.router.cfg(cfg)
vshard.router.static.replicasets[util.replicasets[1]].bucket_count
vshard.router.static.replicasets[util.replicasets[2]].bucket_count


--
-- Test lua errors.
--
_, e = vshard.router.callro(1, 'raise_client_error', {}, {})
e.trace = nil
e
tostring(e)
_, e = vshard.router.route(1):callro('raise_client_error', {})
e.trace = nil
e
tostring(e)
-- Ensure, that despite not working multi-return, it is allowed
-- to return 'nil, err_obj'.
vshard.router.callro(1, 'echo', {nil, 'error_object'}, {})

--
-- gh-48: more precise error messages about bucket unavailability.
--
util.check_error(vshard.router.call, vshard.consts.DEFAULT_BUCKET_COUNT + 1, 'read', 'echo', {123})
util.check_error(vshard.router.call, -1, 'read', 'echo', {123})
util.check_error(vshard.router.call, 0, 'read', 'echo', {123})
replicaset, err = vshard.router.bucket_discovery(0); return err == nil or err
replicaset, err = vshard.router.bucket_discovery(1); return err == nil or err
replicaset, err = vshard.router.bucket_discovery(2); return err == nil or err

_ = test_run:switch('storage_2_a')
box.space._bucket:replace({1, vshard.consts.BUCKET.SENDING, util.replicasets[1]})
_ = test_run:switch('storage_1_a')
box.space._bucket:replace({1, vshard.consts.BUCKET.RECEIVING, util.replicasets[2]})
_ = test_run:switch('router_1')
-- Ok to read sending bucket.
vshard.router.call(1, 'read', 'echo', {123})
-- Not ok to write sending bucket.
util.check_error(vshard.router.call, 1, 'write', 'echo', {123})

_ = test_run:switch('storage_2_a')
box.space._bucket:replace({1, vshard.consts.BUCKET.ACTIVE})
_ = test_run:switch('storage_1_a')
box.space._bucket:delete({1})
_ = test_run:switch('router_1')

-- Check unavailability of master of a replicaset.
_ = vshard.router.bucket_discovery(2)
_ = vshard.router.bucket_discovery(3)
vshard.router.buckets_info(0, 3)
_ = test_run:cmd('stop server storage_2_a')
util.check_error(vshard.router.call, 1, 'read', 'echo', {123})
vshard.router.buckets_info(0, 3)
_ = test_run:cmd('start server storage_2_a')

--
-- gh-26: API to get netbox by bucket identifier.
--
vshard.router.route(vshard.consts.DEFAULT_BUCKET_COUNT + 100)
util.check_error(vshard.router.route, 'asdfg')
util.check_error(vshard.router.route)
conn = vshard.router.route(1).master.conn
conn.state
-- Test missing master.
rs = vshard.router.static.replicasets[util.replicasets[2]]
master = rs.master
rs.master = nil
vshard.router.route(1).master
rs.master = master
-- Test reconnect on bucker_route().
master.conn:close()
conn = vshard.router.route(1):connect()
conn:wait_connected()
conn.state

--
-- gh-44: API to get connections to all replicasets.
--
map = vshard.router.routeall()
uuids = {}
for uuid, _ in pairs(map) do table.insert(uuids, uuid) end
uuids

--
-- gh-69: aliases for router.call - callro and callrw.
--
bucket_id = 1
vshard.router.callrw(bucket_id, 'space_insert', {'test', {1, bucket_id}})
vshard.router.callrw(bucket_id, 'vshard.storage.sync', {})
vshard.router.callro(bucket_id, 'space_get', {'test', {1}})
vshard.router.callro(bucket_id + 1500, 'space_get', {'test', {1}}) -- nothing
-- Check that call does not modify its argument.
opts = {}
vshard.router.callrw(bucket_id, 'echo', {'echo'}, opts)
opts
opts = {}
vshard.router.callro(bucket_id, 'echo', {'echo'}, opts)
opts
opts = {}
vshard.router.route(bucket_id):callrw('echo', {'echo'}, opts)
opts
opts = {}
vshard.router.route(bucket_id):callro('echo', {'echo'}, opts)
opts

--
-- gh-82: support box.session.push().
--
messages = {}
args = {100, 200}
opts = {on_push = table.insert, on_push_ctx = messages}
vshard.router.callrw(bucket_id, 'do_push', args, opts)
messages
messages[1] = nil
vshard.router.callro(bucket_id, 'do_push', args, opts)
messages
messages[1] = nil
vshard.router.route(bucket_id):callro('do_push', args, opts)
messages
messages[1] = nil
vshard.router.route(bucket_id):callrw('do_push', args, opts)
messages

--
-- gh-171: support is_async.
--
future = vshard.router.callro(bucket_id, 'space_get', {'test', {1}}, {is_async = true})
future:wait_result()
future:is_ready()
future = vshard.router.callrw(bucket_id, 'raise_client_error', {}, {is_async = true})
future:wait_result()
future:is_ready()
future = vshard.router.callrw(bucket_id, 'do_push', args, {is_async = true})
func, iter, i = future:pairs()
i, res = func(iter, i)
res
i, res = func(iter, i)
res
func(iter, i)
future:wait_result()
future:is_ready()

future = vshard.router.route(bucket_id):callro('space_get', {'test', {1}}, {is_async = true})
future:wait_result()
future = vshard.router.route(bucket_id):callrw('space_get', {'test', {1}}, {is_async = true})
future:wait_result()

--
-- Test errors from router call.
--
new_bid = vshard.consts.DEFAULT_BUCKET_COUNT + 1
space_data = {{1000, {{1}, {2}}}}
-- Insert in a not existing space - it must return box.error.
vshard.router.call(bucket_id, 'write', 'vshard.storage.bucket_recv', {new_bid, 'from_uuid', space_data})

--
-- Monitoring
--

-- All is ok, when all servers are up.
-- gh-103: show bucket info for each replicaset.
info = vshard.router.info()
while #info.alerts ~= 0 do vshard.router.discovery_wakeup() fiber.sleep(0.01) info = vshard.router.info() end
info

-- Remove replica and master connections to trigger alert
-- UNREACHABLE_REPLICASET.
rs = vshard.router.static.replicasets[util.replicasets[1]]
master_conn = rs.master.conn
replica_conn = rs.replica.conn
rs.master.conn = nil
rs.replica.conn = nil
info = vshard.router.info()
info.replicasets[rs.uuid]
info.status
info.alerts
rs.master.conn = master_conn
rs.replica.conn = replica_conn

-- Trigger alert MISSING_MASTER by manual removal of master.
master = rs.master
rs.master = nil
info = vshard.router.info()
info.replicasets[rs.uuid]
info.status
info.alerts
rs.master = master

buckets_info = vshard.router.buckets_info()
#buckets_info
buckets_info[1]
buckets_info[1501]

vshard.router.buckets_info(0, 3)
vshard.router.buckets_info(1500, 3)
vshard.router.buckets_info(vshard.consts.DEFAULT_BUCKET_COUNT - 3)
util.check_error(vshard.router.buckets_info, '123')
util.check_error(vshard.router.buckets_info, 123, '456')

--
-- gh-51: discovery fiber.
--
_ = test_run:cmd("setopt delimiter ';'")
function calculate_known_buckets()
    local known_buckets = 0
    for _, rs in pairs(vshard.router.static.route_map) do
        known_buckets = known_buckets + 1
    end
    return known_buckets
end;
function wait_discovery()
    local known_buckets = 0
    while known_buckets ~= vshard.consts.DEFAULT_BUCKET_COUNT do
        vshard.router.discovery_wakeup()
        fiber.sleep(0.1)
        known_buckets = calculate_known_buckets()
    end
end;
_ = test_run:cmd("setopt delimiter ''");
-- Pin some buckets to ensure, that pinned buckets are discovered
-- too.
_ = test_run:switch('storage_1_a')
first_active = box.space._bucket.index.status:select({vshard.consts.BUCKET.ACTIVE}, {limit = 1})[1].id
vshard.storage.bucket_pin(first_active)
_ = test_run:switch('storage_2_a')
first_active = box.space._bucket.index.status:select({vshard.consts.BUCKET.ACTIVE}, {limit = 1})[1].id
vshard.storage.bucket_pin(first_active)
_ = test_run:switch('router_1')
wait_discovery()
calculate_known_buckets()
test_run:grep_log('router_1', 'was 1, became 1500')
info = vshard.router.info()
info.bucket
info.alerts
_ = test_run:switch('storage_1_a')
vshard.storage.bucket_unpin(first_active)
_ = test_run:switch('storage_2_a')
vshard.storage.bucket_unpin(first_active)
_ = test_run:switch('router_1')

--
-- Ensure the discovery procedure works continuously.
--
_ = test_run:cmd("setopt delimiter ';'")
for i = 1, 100 do
    local rs = vshard.router.static.route_map[i]
    assert(rs)
    rs.bucket_count = rs.bucket_count - 1
    vshard.router.static.route_map[i] = nil
end;
_ = test_run:cmd("setopt delimiter ''");
calculate_known_buckets()
info = vshard.router.info()
info.bucket
info.alerts
wait_discovery()
calculate_known_buckets()
test_run:grep_log('router_1', 'was 1400, became 1500')
info = vshard.router.info()
info.bucket
info.alerts

--
-- Configuration: inconsistency master=true on storage and routers
--
-- This test case flips masters in replicasets without changing
-- configuration on router and tests NON_MASTER response
--

-- Test the WRITE request
vshard.router.call(1, 'write', 'echo', { 'hello world' })

-- Shuffle masters
util.shuffle_masters(cfg)

-- Reconfigure storages
_ = test_run:switch("storage_1_a")
cfg.sharding = test_run:eval('router_1', 'return cfg.sharding')[1]
vshard.storage.cfg(cfg, util.name_to_uuid.storage_1_a)

_ = test_run:switch("storage_1_b")
cfg.sharding = test_run:eval('router_1', 'return cfg.sharding')[1]
vshard.storage.cfg(cfg, util.name_to_uuid.storage_1_b)

_ = test_run:switch("storage_2_a")
cfg.sharding = test_run:eval('router_1', 'return cfg.sharding')[1]
vshard.storage.cfg(cfg, util.name_to_uuid.storage_2_a)

_ = test_run:switch("storage_2_b")
cfg.sharding = test_run:eval('router_1', 'return cfg.sharding')[1]
vshard.storage.cfg(cfg, util.name_to_uuid.storage_2_b)

-- Test that the WRITE request doesn't work
_ = test_run:switch("router_1")
util.check_error(vshard.router.call, 1, 'write', 'echo', { 'hello world' })

-- Reconfigure router and test that the WRITE request does work
vshard.router.cfg(cfg)
vshard.router.call(1, 'write', 'echo', { 'hello world' })

-- Sync API
vshard.router.sync()
util.check_error(vshard.router.sync, "xxx")
vshard.router.sync(100500)

--
-- gh-81: Check that user passed self arg.
-- This check ensures that in case a vshard user called an
-- object method like this: object.method() instead of
-- object:method(), an appropriate help-error returns.
--
_, replicaset = next(vshard.router.static.replicasets)
error_messages = {}

_ = test_run:cmd("setopt delimiter ';'")
for _, func in pairs(getmetatable(replicaset).__index) do
    local ok, msg = pcall(func, "arg_of_wrong_type")
    table.insert(error_messages, msg:match("Use .*"))
end;
_ = test_run:cmd("setopt delimiter ''");
error_messages

_, replica = next(replicaset.replicas)
error_messages = {}

_ = test_run:cmd("setopt delimiter ';'")
for _, func in pairs(getmetatable(replica).__index) do
    local ok, msg = pcall(func, "arg_of_wrong_type")
    table.insert(error_messages, msg:match("Use .*"))
end;
_ = test_run:cmd("setopt delimiter ''");
error_messages

--
-- gh-117: Preserve route_map on router.cfg.
--
bucket_to_old_rs = {}
bucket_cnt = 0
_ = test_run:cmd("setopt delimiter ';'")
for bucket, rs in pairs(vshard.router.static.route_map) do
    bucket_to_old_rs[bucket] = rs
    bucket_cnt = bucket_cnt + 1
end;
bucket_cnt;
vshard.router.cfg(cfg);
for bucket, old_rs in pairs(bucket_to_old_rs) do
    local old_uuid = old_rs.uuid
    local rs = vshard.router.static.route_map[bucket]
    if not rs or not old_uuid == rs.uuid then
        error("Bucket lost during reconfigure.")
    end
    if rs == old_rs then
        error("route_map was not updataed.")
    end
end;

--
-- Check route_map is not filled with old replica objects after
-- reconfigure.
--
-- Simulate long `callro`.
vshard.router.internal.errinj.ERRINJ_LONG_DISCOVERY = true;
while vshard.router.internal.errinj.ERRINJ_LONG_DISCOVERY ~= 'waiting' do
    vshard.router.discovery_wakeup()
    fiber.sleep(0.02)
end;
vshard.router.cfg(cfg);
vshard.router.static.route_map = {};
vshard.router.internal.errinj.ERRINJ_LONG_DISCOVERY = false;
-- Do discovery iteration. Upload buckets from the
-- first replicaset.
while not next(vshard.router.static.route_map) do
    vshard.router.discovery_wakeup()
    fiber.sleep(0.01)
end;
new_replicasets = {};
for _, rs in pairs(vshard.router.static.replicasets) do
    new_replicasets[rs] = true
end;
_, rs = next(vshard.router.static.route_map);
new_replicasets[rs] == true;
_ = test_run:cmd("setopt delimiter ''");

-- gh-114: Check non-dynamic option change during reconfigure.
non_dynamic_cfg = table.copy(cfg)
non_dynamic_cfg.shard_index = 'non_default_name'
util.check_error(vshard.router.cfg, non_dynamic_cfg)

-- Error during reconfigure process.
vshard.router.route(1):callro('echo', {'some_data'})
vshard.router.internal.errinj.ERRINJ_CFG = true
old_internal = table.copy(vshard.router.internal)
util.check_error(vshard.router.cfg, cfg)
vshard.router.internal.errinj.ERRINJ_CFG = false
util.has_same_fields(old_internal, vshard.router.internal)
vshard.router.route(1):callro('echo', {'some_data'})

-- Multiple routers: check that static router can be used as an
-- object.
vshard.router.static:route(1):callro('echo', {'some_data'})

_ = test_run:switch("default")
test_run:drop_cluster(REPLICASET_2)

-- gh-24: log all connnect/disconnect events.
while test_run:grep_log('router_1', 'disconnected from ') == nil do fiber.sleep(0.1) end

_ = test_run:cmd("stop server router_1")
_ = test_run:cmd("cleanup server router_1")
test_run:drop_cluster(REPLICASET_1)
_ = test_run:cmd('clear filter')
