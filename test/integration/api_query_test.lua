local fio = require('fio')
local t = require('luatest')
local g = t.group()

local helpers = require('test.helper')
local log = require('log')

g.before_all(function()
    g.cluster = helpers.Cluster:new({
        datadir = fio.tempdir(),
        server_command = helpers.entrypoint('srv_basic'),
        use_vshard = true,
        cookie = helpers.random_cookie(),

        replicasets = {
            {
                uuid = helpers.uuid('a'),
                roles = {'vshard-router'},
                servers = {
                    {
                        alias = 'router',
                        instance_uuid = helpers.uuid('a', 'a', 1),
                        advertise_port = 13301,
                        http_port = 8081
                    }
                }
            }, {
                uuid = helpers.uuid('b'),
                roles = {'vshard-storage'},
                all_rw = true,
                servers = {
                    {
                        alias = 'storage',
                        instance_uuid = helpers.uuid('b', 'b', 1),
                        advertise_port = 13302,
                        http_port = 8082
                    }, {
                        alias = 'storage-2',
                        instance_uuid = helpers.uuid('b', 'b', 2),
                        advertise_port = 13304,
                        http_port = 8084
                    }
                }
            }, {
                uuid = helpers.uuid('c'),
                roles = {},
                servers = {
                    {
                        alias = 'expelled',
                        instance_uuid = helpers.uuid('c', 'c', 1),
                        advertise_port = 13309,
                        http_port = 8089
                    }
                }
            }
        }
    })
    g.cluster:start()

    g.cluster:server('expelled'):eval([[
        local last_will_path = ...
        last_will_path = require('fio').pathjoin(last_will_path, 'last_will.txt')
        package.loaded['mymodule-permanent'].stop = function()
            require('cartridge.utils').file_write(last_will_path,

                "In the name of God, amen! I Expelled in perfect health"..
                "and memorie, God be praysed, doe make and ordayne this"..
                "my last will and testament in manner and forme"..
                "followeing, that ys to saye, first, I comend my soule"..
                "into the handes of God my Creator, hoping and"..
                "assuredlie beleeving, through thonelie merites of Jesus"..
                "Christe my Saviour, to be made partaker of lyfe"..
                "everlastinge, and my bodye to the earth whereof yt ys"..
                "made.")

        end
    ]], {g.cluster.datadir})

    g.cluster:server('expelled'):stop()
    g.cluster:server('router'):graphql({
        query = [[
            mutation($uuid: String!) {
                expelServerResponse: cluster{edit_topology(
                    servers: [{
                        uuid: $uuid
                        expelled: true
                    }]
                ) {
                    servers{status}
                }}
            }
        ]],
        variables = {
            uuid = g.cluster:server('expelled').instance_uuid
        }
    })

    g.server = helpers.Server:new({
        workdir = fio.tempdir(),
        alias = 'spare',
        command = helpers.entrypoint('srv_basic'),
        replicaset_uuid = helpers.uuid('b'),
        instance_uuid = helpers.uuid('b', 'b', 1),
        http_port = 8083,
        cluster_cookie = g.cluster.cookie,
        advertise_port = 13303,
        env = {
            TARANTOOL_WEBUI_BLACKLIST = '/cluster/code:/cluster/schema',
        }
    })

    g.server:start()
    t.helpers.retrying({timeout = 5}, function()
        g.server:graphql({query = '{ servers { uri } }'})
        g.cluster.main_server:graphql({
            query = 'mutation($uri: String!) { probe_server(uri:$uri) }',
            variables = {uri = g.server.advertise_uri},
        })
    end)
end)

g.before_each(function()
    helpers.retrying({}, function()
        t.assert_equals(helpers.list_cluster_issues(g.cluster.main_server), {})
    end)
end)

g.after_all(function()
    g.cluster:stop()
    g.server:stop()
    fio.rmtree(g.cluster.datadir)
    fio.rmtree(g.server.workdir)
end)

local function fields_from_map(map, field_key)
    local data_arr = {}
    for _, v in pairs(map['fields']) do
        table.insert(data_arr, v[field_key])
    end
    return data_arr
end

function g.test_self()
    local router_server = g.cluster:server('router')

    local resp = router_server:graphql({
        query = [[
            {
                cluster {
                    self {
                        uri
                        uuid
                        alias
                    }
                    can_bootstrap_vshard
                    vshard_bucket_count
                    vshard_known_groups
                }
            }
        ]]
    })

    t.assert_equals(resp['data']['cluster'], {
        self = {
            uri = string.format( "localhost:%d", router_server.net_box_port),
            uuid = router_server.instance_uuid,
            alias = router_server.alias,
        },
        can_bootstrap_vshard = false,
        vshard_bucket_count = 3000,
        vshard_known_groups = {'default'}
    })

    local function _get_demo_uri()
        return router_server:graphql({query = [[{
            cluster { self { demo_uri } } }
        ]]}).data.cluster.self.demo_uri
    end

    t.assert_equals(_get_demo_uri(), box.NULL)

    local demo_uri = 'http://try-cartridge.tarantool.io'
    router_server:eval([[
        os.setenv('TARANTOOL_DEMO_URI', ...)
    ]], {demo_uri})

    t.assert_equals(_get_demo_uri(), demo_uri)
end

function g.test_suggestions()
    local suggestions = g.cluster.main_server:graphql({
        query = [[{
            cluster { suggestions {
                refine_uri { uuid }
                force_apply { uuid }
                disable_servers { uuid }
                restart_replication { uuid }
            }}
        }]]
    }).data.cluster.suggestions

    t.assert_equals(suggestions, {
        refine_uri = box.NULL,
        force_apply = box.NULL,
        disable_servers = box.NULL,
        restart_replication = box.NULL,
    })
end

function g.test_custom_http_endpoint()
    local router = g.cluster:server('router')
    local resp = router:http_request('get', '/custom-get')
    t.assert_equals(resp['body'], 'GET OK')

    local resp = router:http_request('post', '/custom-post')
    t.assert_equals(resp['body'], 'POST OK')
end


function g.test_server_stat_schema()
    local router = g.cluster:server('router')
    local resp = router:graphql({
        query = [[{
            __type(name: "ServerStat") {
                fields { name }
            }
        }]]
    })

    local field_names = fields_from_map(resp['data']['__type'], 'name')
    t.assert_items_equals(field_names, {
        'items_size', 'items_used', 'items_used_ratio',
        'quota_size', 'quota_used', 'quota_used_ratio',
        'arena_size', 'arena_used', 'arena_used_ratio',
        'vshard_buckets_count'
    })

    local stat_fields_str = table.concat(field_names, ' ')
    local resp = router:graphql({
        query = string.format([[{
            servers {
                statistics { %s }
            }
        }]], stat_fields_str)
    })
    log.info(resp['data']['servers'][1])
end

function g.test_server_info_schema()
    local router = g.cluster:server('router')
    local resp = router:graphql({
        query = [[{
            general_fields: __type(name: "ServerInfoGeneral") {
                fields { name }
            }
            storage_fields: __type(name: "ServerInfoStorage") {
                fields { name }
            }
            network_fields: __type(name: "ServerInfoNetwork") {
                fields { name }
            }
            replication_fields: __type(name: "ServerInfoReplication") {
                fields { name }
            }
            cartridge_fields: __type(name: "ServerInfoCartridge") {
                fields { name }
            }
            vshard_storage_fields: __type(name: "ServerInfoVshardStorage") {
                fields { name }
            }
            membership_fields: __type(name: "ServerInfoMembership") {
                fields { name }
            }
        }]]
    })

    local data = resp['data']
    local field_name_general = fields_from_map(data['general_fields'], 'name')
    local field_name_storage = fields_from_map(data['storage_fields'], 'name')
    local field_name_network = fields_from_map(data['network_fields'], 'name')
    local field_name_replica = fields_from_map(data['replication_fields'], 'name')
    local field_name_cartridge = fields_from_map(data['cartridge_fields'], 'name')
    local field_name_vshard_storage = fields_from_map(data['vshard_storage_fields'], 'name')
    local field_name_membership = fields_from_map(data['membership_fields'], 'name')

    local query = string.format(
            [[
                {
                    servers {
                        boxinfo {
                            general { %s }
                            storage { %s }
                            network { %s }
                            replication { %s }
                            cartridge { %s }
                            vshard_storage { %s }
                            membership { %s }
                        }
                    }
                }
            ]],
            table.concat(field_name_general, ' '),
            table.concat(field_name_storage, ' '),
            table.concat(field_name_network, ' '),
            table.concat(field_name_replica, ' '),
            table.concat(field_name_cartridge, ' '),
            table.concat(field_name_vshard_storage, ' '),
            table.concat(field_name_membership, ' '))
            -- workaround composite graphql type
                :gsub('error', 'error { message }')
                :gsub('replication_info', 'replication_info { id upstream_lag downstream_lag }')

    local resp = router:graphql({
        query = query,
    })
    log.info(resp['data']['servers'][1])
end

function g.test_replication_info_schema()
    local router = g.cluster:server('router')
    local resp = router:graphql({
        query = [[{
            __type(name: "ReplicaStatus") {
                fields { name }
            }
        }]]
    })

    local field_names = fields_from_map(resp['data']['__type'], 'name')
    log.info(field_names)

    local replica_fields_str = table.concat(field_names, ' ')
    router:graphql({
        query = string.format([[{
            servers {
                boxinfo {
                    replication {
                        replication_info {
                            %s
                        }
                    }
                }
            }
        }]],  replica_fields_str)
    })
end

function g.test_servers()
    local router = g.cluster:server('router')
    local app_version = 'app_version_test_value'

    local resp = router:graphql({
        query = [[
            {
                servers {
                    uri
                    uuid
                    alias
                    labels { name }
                    disabled
                    priority
                    replicaset { roles }
                    statistics { vshard_buckets_count }
                    boxinfo {
                        cartridge { state error { message class_name } }
                        membership { status }
                        vshard_router { buckets_unreachable }
                        vshard_storage { buckets_active }
                        general {
                            app_version
                            http_port
                            http_host
                            webui_prefix
                        }
                    }
                }
            }
        ]]
    })

    table.sort(resp['data']['servers'], function(a, b) return a.uri < b.uri end)

    t.assert_items_equals(resp['data']['servers'], {{
            uri = 'localhost:13301',
            uuid = helpers.uuid('a', 'a', 1),
            alias = 'router',
            labels = {},
            priority = 1,
            disabled = false,
            statistics = {vshard_buckets_count = box.NULL},
            replicaset = {roles = {'vshard-router'}},
            boxinfo = {
                cartridge = {error = box.NULL, state = "RolesConfigured"},
                membership = {status = 'alive'},
                vshard_router = {{ buckets_unreachable = 0 }},
                vshard_storage = box.NULL,
                general = { app_version = app_version, http_port = 8081, http_host = "0.0.0.0", webui_prefix = "" },
            },
        }, {
            uri = 'localhost:13302',
            uuid = helpers.uuid('b', 'b', 1),
            alias = 'storage',
            labels = {},
            priority = 1,
            disabled = false,
            statistics = {vshard_buckets_count = 3000},
            replicaset = {roles = {'vshard-storage'}},
            boxinfo = {
                cartridge = {error = box.NULL, state = "RolesConfigured"},
                membership = {status = 'alive'},
                vshard_router = box.NULL,
                vshard_storage = {buckets_active = 3000},
                general = { app_version = app_version, http_port = 8082, http_host = "0.0.0.0", webui_prefix = "" },
            },
        }, {
            uri = 'localhost:13304',
            uuid = helpers.uuid('b', 'b', 2),
            alias = 'storage-2',
            labels = {},
            priority = 2,
            disabled = false,
            statistics = {vshard_buckets_count = 3000},
            replicaset = {roles = {'vshard-storage'}},
            boxinfo = {
                cartridge = {error = box.NULL, state = "RolesConfigured"},
                membership = {status = 'alive'},
                vshard_router = box.NULL,
                vshard_storage = {buckets_active = 3000},
                general = { app_version = app_version, http_port = 8084, http_host = "0.0.0.0", webui_prefix = "" },
            },
        }, {
            uri = 'localhost:13303',
            uuid = '',
            alias = 'spare',
            labels = box.NULL,
            priority = box.NULL,
            disabled = box.NULL,
            statistics = box.NULL,
            replicaset = box.NULL,
            boxinfo = box.NULL,
        }
    })
end

function g.test_replicasets()
    local resp = g.cluster:server('router'):graphql({
        query = [[
            {
                replicasets {
                    uuid
                    alias
                    roles
                    status
                    master { uuid }
                    active_master { uuid }
                    servers { uri priority }
                    all_rw
                    weight
                }
            }
        ]]
    })

    t.assert_items_equals(resp.data.replicasets, {{
            uuid = helpers.uuid('a'),
            alias = 'unnamed',
            roles = {'vshard-router'},
            status = 'healthy',
            master = {uuid = helpers.uuid('a', 'a', 1)},
            active_master = {uuid = helpers.uuid('a', 'a', 1)},
            servers = {{uri = 'localhost:13301', priority = 1}},
            all_rw = false,
            weight = box.NULL,
        }, {
            uuid = helpers.uuid('b'),
            alias = 'unnamed',
            roles = {'vshard-storage'},
            status = 'healthy',
            master = {uuid = helpers.uuid('b', 'b', 1)},
            active_master = {uuid = helpers.uuid('b', 'b', 1)},
            weight = 1,
            all_rw = true,
            servers = {
                {uri = 'localhost:13302', priority = 1},
                {uri = 'localhost:13304', priority = 2},
            }
        }
    })
end

function g.test_probe_server()
    local router = g.cluster:server('router')
    local probe_req = function(vars)
        return router:graphql({
            query = 'mutation($uri: String!) { probe_server(uri:$uri) }',
            variables = vars
        })
    end

    t.assert_error_msg_contains(
        'Probe "localhost:9" failed: no response',
        probe_req, {uri = 'localhost:9'}
    )

    t.assert_error_msg_contains(
        'Probe "bad-host" failed: ping was not sent',
        probe_req, {uri = 'bad-host'}
    )

    local resp = probe_req({uri = router.advertise_uri})
    t.assert_equals(resp['data']['probe_server'], true)
end

function g.test_clock_delta()
    local router = g.cluster:server('router')

    local resp = router:graphql({
        query = [[{ servers { uri clock_delta } }]]
    })

    local servers = resp['data']['servers']

    t.assert_equals(#servers, 4)
    for _, server in pairs(servers) do
        t.assert_almost_equals(server.clock_delta, 0, 0.1)
    end
end

function g.test_topology_caching()
    -- In this test we protect `admin.get_topology` function from being
    -- executed twice in the same request and query same data with
    -- different aliases
    g.cluster.main_server:eval([[
        local fiber = require('fiber')
        local lua_api_topology = require('cartridge.lua-api.topology')
        local __get_topology = lua_api_topology.get_topology
        lua_api_topology.get_topology = function()
            assert(
                not fiber.self().storage.get_topology_wasted,
                "Excess get_topology call"
            )
            fiber.self().storage.get_topology_wasted = true
            return __get_topology()
        end
    ]])

    local resp = g.cluster.main_server:graphql({
        query = [[{
            s1: servers {alias}
            s2: servers {alias}
            replicasets {servers { uri }}
        }]],
    })

    t.assert_equals(resp.data.s1, resp.data.s2)

    local resp = g.cluster.main_server:graphql({
        query = [[{
            r1: replicasets {servers {replicaset {servers { uuid }}}}
            r2: replicasets {servers {replicaset {servers { uuid }}}}
        }]],
    })

    t.assert_equals(resp.data.r1, resp.data.r2)
end

function g.test_operation_error()
    local victim = g.cluster:server('storage-2')
    helpers.run_remotely(victim, function()
        local mymodule = package.loaded['mymodule-permanent']
        rawset(_G, 'apply_config_original', mymodule.apply_config)
        mymodule.apply_config = function()
            error('Artificial Error', 0)
        end
    end)

    local query = [[ mutation($sections: [ConfigSectionInput]) {
        cluster { config(sections: $sections) { filename } }
    }]]

    -- Dummy mutation doesn't trigger two-phase commit
    g.cluster.main_server:graphql({
        query = query, variables = {sections = {}},
    })

    -- Real tho-phase commit causes OperationError
    local txt = {filename = "x.txt", content = "oops"}
    local resp = g.cluster.main_server:graphql({
        query = query, variables = {sections = {txt}},
        raise = false,
    })

    local err = resp.errors[1]
    t.assert_covers(err, {message = '"localhost:13304": Artificial Error'})
    t.assert_covers(err.extensions, {
        ['io.tarantool.errors.class_name'] = 'ApplyConfigError',
    })

    local victim_info = g.cluster.main_server:graphql({
        query = [[query($uuid: String!){
            servers(uuid: $uuid) {
                boxinfo {cartridge {
                    state
                    error { message class_name stack}
                }}
            }
        }]],
        variables = {uuid = victim.instance_uuid},
    }).data.servers[1].boxinfo.cartridge

    t.assert_equals(victim_info.state, 'OperationError')
    t.assert_covers(victim_info.error, {
        message = 'Artificial Error',
        class_name = 'ApplyConfigError',
    })

    -- Revert all hacks and fix the cluster
    helpers.run_remotely(victim, function()
        local mymodule = package.loaded['mymodule-permanent']
        mymodule.apply_config = _G.apply_config_original
        _G.apply_config_original = nil
    end)

    local resp = g.cluster.main_server:graphql({
        query = '{cluster {config {filename content}}}'
    })
    t.assert_items_include(resp.data.cluster.config, {txt})

    -- An attempt to reapply the same config shouldn't
    -- be skipped in the OperationError state
    g.cluster.main_server:graphql({
        query = query, variables = {sections = {txt}},
    })

    g.cluster:wait_until_healthy(g.cluster.main_server)
end

function g.test_webui_blacklist()
    local query = '{ cluster { webui_blacklist }}'

    t.assert_equals(
        g.cluster.main_server:graphql({query = query}).data.cluster,
        {webui_blacklist = {}}
    )

    t.assert_equals(
        g.server:graphql({query = query}).data.cluster,
        {webui_blacklist = {'/cluster/code', '/cluster/schema'}}
    )
end

function g.test_app_name()
    local function get_app_info()
        return g.server:graphql({query = [[{
            cluster {
                self {
                    app_name
                    instance_name
                }
            }
        }]]}).data.cluster.self
    end
    t.assert_equals(get_app_info(), {app_name = box.NULL, instance_name = box.NULL})

    g.server:stop()
    g.server.env['TARANTOOL_APP_NAME'] = 'app_name'
    g.server.env['TARANTOOL_INSTANCE_NAME'] = 'instance_name'
    g.server:start()

    t.helpers.retrying({timeout = 5}, function()
        g.server:graphql({query = '{ servers { uri } }'})
    end)

    t.assert_equals(get_app_info(), {app_name = 'app_name', instance_name = 'instance_name'})
end

function g.test_membership_leave()
    t.skip_if(box.ctl.on_shutdown == nil,
        'box.ctl.on_shutdown is not supported' ..
        ' in Tarantool ' .. _TARANTOOL
    )

    t.assert_equals(
        g.cluster.main_server:eval([[
            local membership = require('membership')
            local member = membership.members()[...]
            return member.status
        ]], {g.cluster:server('expelled').advertise_uri}),
        'left'
    )
end


function g.test_issues()
    -----------------------------------------------------------------------------
    -- memory usage issues
    local server = g.cluster:server('storage')
    server:eval([[
        _G._old_slab_info = box.slab.info
        _G._slab_data = {
            items_used = 6.1,
            items_size = 0,
            quota_used = 9.1,
            quota_size = 10,
            arena_used = 9.1,
            arena_size = 10,
            arena_used_ratio = '91.00%',
            items_used_ratio = '6100000.00%',
            quota_used_ratio = '91.00%',
        }
        box.slab.info = function ()
            return _G._slab_data
        end
    ]])

    t.assert_equals(
        helpers.list_cluster_issues(g.cluster.main_server),
        {{
            level = 'critical',
            topic = 'memory',
            message = 'Running out of memory on localhost:13302 (storage):' ..
            ' used 6100000.00% (items), 91.00% (arena), 91.00% (quota)',
            replicaset_uuid = box.NULL,
            instance_uuid = server.instance_uuid,
        }}
    )
    server:eval([[
        _G._slab_data.items_size = 10
        _G._slab_data.items_used_ratio = '61.00%'
   ]])
    t.assert_equals(
        helpers.list_cluster_issues(g.cluster.main_server),
        {{
            level = 'warning',
            topic = 'memory',
            message = 'Memory is highly fragmented on localhost:13302 (storage):' ..
                ' used 61.00% (items), 91.00% (arena), 91.00% (quota)',
            replicaset_uuid = box.NULL,
            instance_uuid = server.instance_uuid,
        }}
    )

    server:eval('box.slab.info = _G._old_slab_info')
    t.assert_equals(helpers.list_cluster_issues(g.cluster.main_server), {})

    -----------------------------------------------------------------------------
    -- clock desync issues
    g.cluster.main_server:eval([[
        require('cartridge.issues').set_limits({clock_delta_threshold_warning = 0})
    ]])
    local issues = helpers.list_cluster_issues(g.cluster.main_server)
    g.cluster.main_server:eval([[
        local vars = require('cartridge.vars').new('cartridge.issues')
        vars.limits = nil -- reset default values
    ]])

    t.assert_covers(issues[1], {
        topic = 'clock',
        level = 'warning',
        instance_uuid = box.NULL,
        replicaset_uuid = box.NULL,
    })
    t.assert_str_matches(issues[1].message,
        'Clock difference between' ..
        ' localhost:%d+ %([%w%-]+%) and localhost:%d+ %([%w%-]+%)' ..
        ' exceed threshold %(.+ > 0%)'
    )
    t.assert_not(next(issues, 1))
end

function g.test_stop_roles_on_shutdown()
    t.skip_if(box.ctl.on_shutdown == nil,
        'box.ctl.on_shutdown is not supported' ..
        ' in Tarantool ' .. _TARANTOOL
    )

    local last_will_path = fio.pathjoin(g.cluster.datadir, 'last_will.txt')

    t.assert_equals(
        fio.path.exists(last_will_path),
        true
    )
end

function g.test_get_enabled_roles_without_deps()
    local res = g.cluster:server('router'):exec(function()
        return require('cartridge.lua-api.get-topology').get_enabled_roles_without_deps()
    end)
    t.assert_equals(res, {'vshard-router'})

    local res = g.cluster:server('storage'):exec(function()
        return require('cartridge.lua-api.get-topology').get_enabled_roles_without_deps()
    end)
    t.assert_equals(res, {'vshard-storage'})
end

function g.test_cartridge_get_topology_iproto()
    local res = g.cluster:server('router'):exec(function()
        require('membership').probe_uri('localhost:13303')
        return require('cartridge.lua-api.get-topology').get_servers()
    end)

    local expected = {{
            alias = "router",
            disabled = false,
            labels = {},
            priority = 1,
            status = "healthy",
            replicaset_uuid = "aaaaaaaa-0000-0000-0000-000000000000",
            uri = "localhost:13301",
            uuid = "aaaaaaaa-aaaa-0000-0000-000000000001",
        }, {
            alias = "storage",
            disabled = false,
            labels = {},
            priority = 1,
            replicaset_uuid = "bbbbbbbb-0000-0000-0000-000000000000",
            uri = "localhost:13302",
            uuid = "bbbbbbbb-bbbb-0000-0000-000000000001",
        }, {
            alias = "spare",
            uri = "localhost:13303",
            uuid = "",
        }, {
            alias = "storage-2",
            disabled = false,
            labels = {},
            priority = 2,
            replicaset_uuid = "bbbbbbbb-0000-0000-0000-000000000000",
            uri = "localhost:13304",
            uuid = "bbbbbbbb-bbbb-0000-0000-000000000002",
    }}

    t.assert_equals(#expected, #res)

    table.sort(expected, function(a,b) return a.uri < b.uri end)
    table.sort(res, function(a,b) return a.uri < b.uri end)
    for i, exp_server in ipairs(expected) do
        t.assert_covers(res[i], exp_server)
    end
end
