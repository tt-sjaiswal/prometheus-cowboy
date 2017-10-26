-module(prometheus_cowboy2_instrumenter).

-export([setup_metrics/0]).
-export([observe/1]).
-define(DEFAULT_DURATION_BUCKETS, [0.01, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 4]).
-define(DEFAULT_EARLY_ERROR_LABELS, []).
-define(DEFAULT_REQUEST_LABELS, [method, reason, status_class]).
-define(DEFAULT_ERROR_LABELS, [method, reason, error]).
-define(DEFAULT_CONFIG, [{duration_buckets, ?DEFAULT_DURATION_BUCKETS},
                         {early_error_labels,  ?DEFAULT_EARLY_ERROR_LABELS},
                         {request_labels, ?DEFAULT_REQUEST_LABELS},
                         {error_labels, ?DEFAULT_ERROR_LABELS}]).

%% ===================================================================
%% API
%% ===================================================================

-spec observe(map()) -> ok.
observe(Metrics0=#{ref:=ListenerRef}) ->
  {Host, Port} = ranch:get_addr(ListenerRef),
  dispatch_metrics(Metrics0#{listener_host=>Host,
                             listener_port=>Port}),
  ok.

setup_metrics() ->
  prometheus_counter:declare([{name, cowboy_early_errors_total},
                              {labels, early_error_labels()},
                              {help, "Total number of Cowboy early errors."}]),
  %% each observe call means new request
  prometheus_counter:declare([{name, cowboy_requests_total},
                              {labels, request_labels()},
                              {help, "Total number of Cowboy requests."}]),
  prometheus_counter:declare([{name, cowboy_spawned_processes_total},
                              {labels, request_labels()},
                              {help, "Total number of spawned processes."}]),
  prometheus_counter:declare([{name, cowboy_errors_total},
                              {labels, error_labels()},
                              {help, "Total number of Cowboy early errors."}]),
  prometheus_histogram:declare([{name, cowboy_request_duration_seconds},
                                {labels, request_labels()},
                                {buckets, duration_buckets()},
                                {help, "Cowboy request duration."}]),
  prometheus_histogram:declare([{name, cowboy_receive_body_duration_seconds},
                                {labels, request_labels()},
                                {buckets, duration_buckets()},
                                {help, "Request body receiving duration."}]),

  ok.

%% ===================================================================
%% Private functions
%% ===================================================================

dispatch_metrics(#{early_time_error := _}=Metrics) ->
  prometheus_counter:inc(cowboy_early_errors_total, early_error_labels(Metrics));
dispatch_metrics(#{req_start := ReqStart,
                   req_end := ReqEnd,
                   req_body_start := ReqBodyStart,
                   req_body_end := ReqBodyEnd,
                   reason := Reason,
                   procs := Procs}=Metrics) ->
  RequestLabels = request_labels(Metrics),
  prometheus_counter:inc(cowboy_requests_total, RequestLabels),
  prometheus_counter:inc(cowboy_spawned_processes_total, RequestLabels, maps:size(Procs)),
  prometheus_histogram:observe(cowboy_request_duration_seconds, RequestLabels,
                               ReqEnd - ReqStart),
  case ReqBodyEnd of
    undefined -> ok;
    _ -> prometheus_histogram:observe(cowboy_receive_body_duration_seconds, RequestLabels,
                                      ReqBodyEnd - ReqBodyStart)
  end,

  case Reason of
    normal ->
      ok;
    switch_protocol ->
      ok;
    stop ->
      ok;
    _ ->
      ErrorLabels = error_labels(Metrics),
      prometheus_counter:inc(cowboy_errors_total, ErrorLabels)
  end.

early_error_labels(Metrics) ->
  compute_labels(early_error_labels(), Metrics).

request_labels(Metrics) ->
  compute_labels(request_labels(), Metrics).

error_labels(Metrics) ->
  compute_labels(error_labels(), Metrics).

compute_labels(Labels, Metrics) ->
  [label_value(Label, Metrics) || Label <- Labels].

label_value(host, #{listener_host:=Host}) ->
  Host;
label_value(port, #{listener_port:=Port}) ->
  Port;
label_value(method, #{req:=Req}) ->
  cowboy_req:method(Req);
label_value(status, #{resp_status:=Status}) ->
  Status;
label_value(status_class, #{resp_status:=Status}) ->
  prometheus_http:status_class(Status);
label_value(reason, #{reason:=Reason}) ->
  case Reason of
    _ when is_atom(Reason) -> Reason;
    {ReasonAtom, _} -> ReasonAtom;
    {ReasonAtom, _, _} -> ReasonAtom
  end;
label_value(error, #{reason:=Reason}) ->
  case Reason of
    _ when is_atom(Reason) -> undefined;
    {_, {Error, _}, _} -> Error;
    {_, Error, _} when is_atom(Error) -> Error;
    _ -> undefined
  end;
label_value(Label, Metrics) ->
  case labels_module() of
    undefined -> undefined;
    Module -> Module:label_value(Label, Metrics)
  end.

config() ->
  application:get_env(prometheus, cowboy_instrumenter, ?DEFAULT_CONFIG).

get_config_value(Key, Default) ->
  proplists:get_value(Key, config(), Default).

duration_buckets() ->
  get_config_value(duration_buckets, ?DEFAULT_DURATION_BUCKETS).

early_error_labels() ->
  get_config_value(early_error_labels, ?DEFAULT_EARLY_ERROR_LABELS).

request_labels() ->
  get_config_value(request_labels, ?DEFAULT_REQUEST_LABELS).

error_labels() ->
  get_config_value(error_labels, ?DEFAULT_ERROR_LABELS).

labels_module() ->
  get_config_value(labels_module, undefined).