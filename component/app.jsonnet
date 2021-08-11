local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.openshift4_splunk_forwarder;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('openshift4-splunk-forwarder', params.namespace);

{
  'openshift4-splunk-forwarder': app,
}
