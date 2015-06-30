-type taskname() :: ergo:taskname().
-type matchable_taskname() :: taskname() | '_'.

-type productname() :: ergo:productname().
-type matchable_productname() :: ergo:productname() | '_'.

-type edge_id() :: integer().
-type matchable_edge_id() :: integer() | '_' | '$1'.

-type batch_id() :: integer().
-type matchable_batch_id() :: integer() | '_'.

-type normalized_product() :: string().
-type matchable_normalized_product() :: string() | '_'.


-type change_report() :: {ok, change_status()} | {err, term()}.
-type change_status() :: changed | no_change.

-record(task,    { name :: taskname(), command :: [binary()]}).
-record(product, { name :: productname() }).
-record(next_id, { kind :: atom(), value :: integer() }).

-record(file_meta, {
          edge_id :: matchable_edge_id(), batch_id :: matchable_batch_id(), removed_id :: matchable_batch_id(),
          about :: matchable_normalized_product(), name :: atom(), value :: term() }).
-record(task_meta, {
          edge_id :: matchable_edge_id(), batch_id :: matchable_batch_id(), removed_id :: matchable_batch_id(),
          about :: matchable_taskname(), name :: atom(), value :: term() }).
-record(seq, {
          edge_id :: matchable_edge_id(), batch_id :: matchable_batch_id(), removed_id :: matchable_batch_id(), before :: matchable_taskname(), then :: matchable_taskname() }).
-record(cotask, {
          edge_id :: matchable_edge_id(), batch_id :: matchable_batch_id(), removed_id :: matchable_batch_id(), task :: matchable_taskname(), also :: matchable_taskname() }).
-record(production, {
          edge_id :: matchable_edge_id(), batch_id :: matchable_batch_id(), removed_id :: matchable_batch_id(), task :: matchable_taskname(), produces :: matchable_normalized_product() }).
-record(requirement, {
          edge_id :: matchable_edge_id(), batch_id :: matchable_batch_id(), removed_id :: matchable_batch_id(), task :: matchable_taskname(), requires :: matchable_normalized_product() }).
-record(dep, {
          edge_id :: matchable_edge_id(), batch_id :: matchable_batch_id(), removed_id :: matchable_batch_id(), from :: matchable_normalized_product(), to :: matchable_normalized_product() }).
-type edge_record() :: #seq{} | #cotask{} | #production{} | #dep{} | #requirement{} | #file_meta{} | #task_meta{}.

-define(edge_id_pos, #seq.edge_id).

-record(provenence, { edge_id :: matchable_edge_id(), task :: matchable_taskname() }).
-record(edge_label, { from_edges :: [edge_id()] }).
-record(gen_edge,   { from :: taskname(), to :: taskname(), implied_by :: [edge_id()] }).

-record(state, { workspace :: ergo:workspace_name(),
                 workspace_root_re :: tuple(),
                 batch_id :: integer(),
                 removed_id :: integer(),
                 edges :: ets:tid(),
                 vertices :: ets:tid(),
                 provenence :: ets:tid()}).
