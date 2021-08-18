// main template for openshift4-splunk-forwarder
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.openshift4_splunk_forwarder;
local app_name = inv.parameters._instance;
local app_selector = {
  name: app_name,
};

local serviceaccount = kube.ServiceAccount(app_name);

local configmap = kube.ConfigMap(app_name) {
  data: {
    'fluentd-loglevel': params.fluentd.loglevel,
    'splunk-insecure': std.toString(params.splunk.insecure),
    'splunk-hostname': params.splunk.hostname,
    'splunk-port': std.toString(params.splunk.port),
    'splunk-protocol': params.splunk.protocol,
    'splunk-index': params.splunk.index,
    'splunk-sourcetype': params.splunk.sourcetype,
    'splunk-source': params.splunk.source,
    'td-agent.conf': |||
      <system>
        log_level "#{ENV['LOG_LEVEL'] }"
      </system>
      <source>
        @type  forward
        @id    input1
        port  24224
        %(tls_config)s
        <security>
          shared_key "#{ENV['SHARED_KEY'] }"
          self_hostname "#{ENV['HOSTNAME']}"
        </security>
      </source>
      <match **>
        @type splunk_hec
        protocol "#{ENV['SPLUNK_PROTOCOL'] }"
        insecure_ssl "#{ENV['SPLUNK_INSECURE'] }"
        hec_host "#{ENV['SPLUNK_HOST'] }"
        sourcetype "#{ENV['SPLUNK_SOURCETYPE'] }"
        source "#{ENV['SPLUNK_SOURCE'] }"
        index "#{ENV['SPLUNK_INDEX'] }"
        hec_port "#{ENV['SPLUNK_PORT'] }"
        hec_token "#{ENV['SPLUNK_TOKEN'] }"
        host "#{ENV['NODE_NAME']}"
        ssl_verify "#{ENV['SPLUNK_SSL_VERIFY']}"
        ca_file /secrets/splunk/splunk-ca.crt
        # TODO: configurize buffer config
        <buffer>
              @type memory
              chunk_limit_records 100000
              chunk_limit_size 200m
              flush_interval 5s
              flush_thread_count 1
              overflow_action block
              retry_max_times 3
              total_limit_size 600m
        </buffer>
        # END: configurize buffer config
      </match>
    ||| % {
      tls_config: if params.fluentd.ssl.enabled then |||
        <transport tls>
          cert_path /secret/fluentd/tls.crt
          private_key_path /secret/fluentd/tls.key
        </transport>
      |||,
    },
  },
};

local secret = kube.Secret(app_name) {
  metadata+: {
    labels+: {
      'app.kubernetes.io/component': 'fluentd',
    },
  },
  stringData: {
    shared_key: params.fluentd.sharedkey,
    'hec-token': params.splunk.token,
    [if params.fluentd.ssl.enabled then 'forwarder-tls.key']: params.fluentd.ssl.key,
    [if params.fluentd.ssl.enabled then 'forwarder-tls.crt']: params.fluentd.ssl.cert,
    [if params.fluentd.ssl.enabled then 'ca-bundle.crt']: params.fluentd.ssl.cert,
  },
};

local secret_splunk = kube.Secret(app_name + '-splunk') {
  metadata+: {
    labels+: {
      'app.kubernetes.io/component': 'fluentd',
    },
  },
  data: {
    'splunk-ca.crt': std.base64(params.splunk.ca),
  },
};

local service_headless = kube.Service(app_name) {
  metadata+: {
    labels+: {
      'app.kubernetes.io/component': 'fluentd',
      name: app_name + '-headless',
    },
    name: app_name + '-headless',
  },
  spec: {
    clusterIP: 'None',
    ports: [ {
      name: '24224-tcp',
      protocol: 'TCP',
      port: 24224,
      targetPort: 24224,
    } ],
    selector: app_selector,
    type: 'ClusterIP',
    sessionAffinity: 'None',
  },
};

local statefulset = kube.StatefulSet(app_name) {
  metadata+: {
    labels+: {
      'app.kubernetes.io/component': 'fluentd',
    },
  },
  spec+: {
    replicas: params.fluentd.replicas,
    template+: {
      spec+: {
        restartPolicy: 'Always',
        terminationGracePeriodSeconds: 30,
        serviceAccount: app_name,
        dnsPolicy: 'ClusterFirst',
        nodeSelector: params.fluentd.nodeselector,
        affinity: params.fluentd.affinity,
        tolerations: params.fluentd.tolerations,
        containers_:: {
          [app_name]: kube.Container(app_name) {
            image: 'registry.redhat.io/openshift4/ose-logging-fluentd:v4.6',
            resources: params.fluentd.resources,
            ports_:: {
              forwarder_tcp: { protocol: 'TCP', containerPort: 24224 },
              forwarder_udp: { protocol: 'UDP', containerPort: 24224 },
            },
            env_:: {
              NODE_NAME: { fieldRef: { apiVersion: 'v1', fieldPath: 'spec.nodeName' } },
              SHARED_KEY: { secretKeyRef: { name: app_name, key: 'shared_key' } },
              SPLUNK_TOKEN: { secretKeyRef: { name: app_name, key: 'hec-token' } },
              LOG_LEVEL: { configMapKeyRef: { name: app_name, key: 'fluentd-loglevel' } },
              SPLUNK_HOST: { configMapKeyRef: { name: app_name, key: 'splunk-hostname' } },
              SPLUNK_SOURCETYPE: { configMapKeyRef: { name: app_name, key: 'splunk-sourcetype' } },
              SPLUNK_SOURCE: { configMapKeyRef: { name: app_name, key: 'splunk-source' } },
              SPLUNK_PORT: { configMapKeyRef: { name: app_name, key: 'splunk-port' } },
              SPLUNK_PROTOCOL: { configMapKeyRef: { name: app_name, key: 'splunk-protocol' } },
              SPLUNK_INSECURE: { configMapKeyRef: { name: app_name, key: 'splunk-insecure' } },
              SPLUNK_INDEX: { configMapKeyRef: { name: app_name, key: 'splunk-index' } },
            },
            args: [ 'fluentd' ],
            livenessProbe: {
              tcpSocket: {
                port: 24224,
              },
              periodSeconds: 5,
              timeoutSeconds: 3,
              initialDelaySeconds: 10,
            },
            readinessProbe: {
              tcpSocket: {
                port: 24224,
              },
              periodSeconds: 3,
              timeoutSeconds: 2,
              initialDelaySeconds: 2,
            },
            terminationMessagePolicy: 'File',
            terminationMessagePath: '/dev/termination-log',
            volumeMounts_:: {
              buffer: { mountPath: '/var/log/fluentd' },
              'fluentd-config': { readOnly: true, mountPath: '/etc/fluent/' },
              [if params.fluentd.ssl.enabled then 'fluentd-certs']:
                { readOnly: true, mountPath: '/secret/fluentd' },
              [if params.splunk.ca != '' then 'splunk-certs']:
                { readOnly: true, mountPath: '/secret/fluentd' },
            },
          },
        },
        volumes_:: {
          buffer:
            { emptyDir: {} },
          'fluentd-config':
            { configMap: { name: app_name, items: [ { key: 'td-agent.conf', path: 'fluent.conf' } ], defaultMode: 420, optional: true } },
          [if params.fluentd.ssl.enabled then 'fluentd-certs']:
            { secret: { secretName: app_name, items: [ { key: 'forwarder-tls.crt', path: 'tls.crt' }, { key: 'forwarder-tls.key', path: 'tls.key' } ] } },
          [if params.splunk.ca != '' then 'splunk-certs']:
            { secret: { secretName: app_name + '-splunk', items: [ { key: 'splunk-ca.crt', path: 'splunk-ca.crt' } ] } },
        },
      },
    },
  },
};


// Define outputs below
{
  '11_serviceaccount': serviceaccount,
  '12_configmap': configmap,
  '13_secret': [
    secret,
    if params.splunk.ca != '' then secret_splunk,
  ],
  '21_service': service_headless,
  '22_statefulset': statefulset,
}
