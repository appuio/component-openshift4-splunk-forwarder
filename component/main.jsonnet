// main template for nfs-subdir-external-provisioner
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.openshift4_splunk_forwarder;
local app_name = inv.parameters._instance;
local app_selector = {
    name: app_name
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
          private_key_passphrase "#{ENV['FLUENTD_SSL_PASSPHRASE'] }"
        </transport>
||| }
  },
};

local secret = kube.Secret(app_name) {
    metadata+: {
        labels+: {
            'app.kubernetes.io/component': 'fluentd',
        },
    },
    data: {
        'shared_key': std.base64(params.fluentd.sharedkey),
        'hec-token': std.base64(params.splunk.token),
        'fluentd-ssl-passsphrase': std.base64(params.fluentd.ssl.passphrase),
    }+ ( if !params.fluentd.ssl.enabled then {} else {
        'forwarder-tls.crt': std.base64(params.fluentd.ssl.cert),
        'forwarder-tls.key': std.base64(params.fluentd.ssl.key),
        'ca-bundle.crt': std.base64(params.fluentd.ssl.cert),  
    })
};

local secret_splunk = kube.Secret(app_name+'-splunk') {
    metadata+: {
        labels+: {
            'app.kubernetes.io/component': 'fluentd',
        },
    },
    data: {
        'splunk-ca.crt': std.base64(params.splunk.ca)
    },
};

local service_spec() = kube.Service(app_name) {
    metadata+: {
        labels+: {
            'app.kubernetes.io/component': 'fluentd',
        },
    },
    spec: {
        ports: [{
            name: '24224-tcp',
            protocol: 'TCP',
            port: 24224,
            targetPort: 24224,
        }],
        selector: app_selector,
        type: 'ClusterIP',
        sessionAffinity: 'None',
    }
};
local service = service_spec();
local service_headless = service_spec() {
    metadata+: {
        labels+: {
            name: app_name+'-headless',
        },
        name: app_name+'-headless'
    },
    spec+: {
        clusterIP: 'None'
    },
};

local statefulset = kube.StatefulSet(app_name) {
    metadata+: {
        labels+: {
            'app.kubernetes.io/component': 'fluentd',
        },
    },
    spec: {
        replicas: params.fluentd.replicas,
        serviceName: app_name,
        updateStrategy: {
            type: "RollingUpdate"
        },
        selector: {
            matchLabels: app_selector,
        },
        template: {
            metadata: {
                labels: app_selector,
            },
            spec: {
                restartPolicy: 'Always',
                terminationGracePeriodSeconds: 30,
                serviceAccount: app_name,
                dnsPolicy: 'ClusterFirst',
                nodeSelector: params.fluentd.nodeselector,
                affinity: params.fluentd.affinity,
                tolerations: params.fluentd.tolerations,
                containers: [{
                    name: app_name,
                    image: 'registry.redhat.io/openshift4/ose-logging-fluentd:v4.6',
                    // imagePullPolicy: 'Always',
                    resources: params.fluentd.resources,
                    ports: [
                        { name: 'forwarder-tcp', protocol: 'TCP', containerPort: 24224 },
                        { name: 'forwarder-udp', protocol: 'UDP', containerPort: 24224 },
                    ],
                    env: [
                        { name: 'NODE_NAME', valueFrom: { fieldRef: { apiVersion: 'v1', fieldPath: 'spec.nodeName' }, }, },
                        { name: 'SHARED_KEY', valueFrom: { secretKeyRef: { name: app_name, key: 'shared_key' }, }, },
                        { name: 'SPLUNK_TOKEN', valueFrom: { secretKeyRef: { name: app_name, key: 'hec-token' }, }, },
                        { name: 'FLUENTD_SSL_PASSPHRASE', valueFrom: { secretKeyRef: { name: app_name, key: 'fluentd-ssl-passsphrase' }, }, },
                        { name: 'LOG_LEVEL', valueFrom: { configMapKeyRef: { name: app_name, key: 'fluentd-loglevel' }, }, },
                        { name: 'SPLUNK_HOST', valueFrom: { configMapKeyRef: { name: app_name, key: 'splunk-hostname' }, }, },
                        { name: 'SPLUNK_SOURCETYPE', valueFrom: { configMapKeyRef: { name: app_name, key: 'splunk-sourcetype' }, }, },
                        { name: 'SPLUNK_SOURCE', valueFrom: { configMapKeyRef: { name: app_name, key: 'splunk-source' }, }, },
                        { name: 'SPLUNK_PORT', valueFrom: { configMapKeyRef: { name: app_name, key: 'splunk-port' }, }, },
                        { name: 'SPLUNK_PROTOCOL', valueFrom: { configMapKeyRef: { name: app_name, key: 'splunk-protocol' }, }, },
                        { name: 'SPLUNK_INSECURE', valueFrom: { configMapKeyRef: { name: app_name, key: 'splunk-insecure' }, }, },
                        { name: 'SPLUNK_INDEX', valueFrom: { configMapKeyRef: { name: app_name, key: 'splunk-index' }, }, },
                    ],
                    args: [ 'fluentd' ],
                    volumeMounts: [
                        { name: 'buffer', mountPath: '/var/log/fluentd' }, 
                        { name: 'fluentd-config', readOnly: true, mountPath: '/etc/fluent/' },
                    ] + ( if !params.fluentd.ssl.enabled then [] else [
                        { name: 'fluentd-certs', readOnly: true, mountPath: '/secret/fluentd' },
                    ]) + ( if params.splunk.ca == "" then [] else [
                        { name: 'splunk-certs', readOnly: true, mountPath: '/secret/splunk' },
                    ]),
                    livenessProbe: {
                        tcpSocket: {
                            port: 24224
                        },
                        periodSeconds: 5,
                        timeoutSeconds: 3,
                        initialDelaySeconds: 10,
                    },
                    readinessProbe: {
                        tcpSocket: {
                            port: 24224
                        },
                        periodSeconds: 3,
                        timeoutSeconds: 2,
                        initialDelaySeconds: 2,
                    },
                    terminationMessagePolicy: 'File',
                    terminationMessagePath: '/dev/termination-log',
                }],
                volumes: [
                    # TODO: if persistence disabled, see below
                    { name: 'buffer', emptyDir: {}, },
                    { name: 'fluentd-config', configMap: { name: app_name, items: [ { key: 'td-agent.conf', path: 'fluent.conf' }, ], defaultMode: 420, optional: true }, },
                ] + ( if !params.fluentd.ssl.enabled then [] else [
                    { 
                      name: 'fluentd-certs', 
                      secret: { 
                        secretName: app_name,
                        items: [ 
                          { key: 'forwarder-tls.crt', path: 'tls.crt' }, 
                          { key: 'forwarder-tls.key', path: 'tls.key' }, 
                        ], 
                      }, 
                    },
                ]) + ( if params.splunk.ca == "" then [] else [
                    { name: 'splunk-certs', secret: { secretName: app_name+'-splunk', items: [ { key: 'splunk-ca.crt', path: 'splunk-ca.crt' }, ], }, },
                ]),
            },
        },
    },
/*
spec:
  {{- if .Values.forwarding.fluentd.persistence.enabled }}
  volumeClaimTemplates:
  - metadata:
      name: buffer
    spec:
      accessModes:
      - {{ .Values.forwarding.fluentd.persistence.accessMode | quote }}
      resources:
        requests:
          storage: {{ .Values.forwarding.fluentd.persistence.size }}
      {{- if .Values.forwarding.fluentd.persistence.storageClass }}
      {{- if (eq "-" .Values.forwarding.fluentd.persistence.storageClass) }}
      storageClassName: ""
      {{- else }}
      storageClassName: "{{ .Values.forwarding.fluentd.persistence.storageClass }}"
      {{- end }}
      {{- end }}
  {{- end }}
*/
};


// Define outputs below
{
  '11_serviceaccount': serviceaccount,
  '12_configmap': configmap,
  '13_secret': [
       secret,
       if params.splunk.ca != "" then secret_splunk
  ],
  '21_service': [
      service,
      service_headless
  ],
  '22_statefulset': statefulset,
}
