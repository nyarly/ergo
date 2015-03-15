-type taskname() :: ergo:taskname().
-type productname() :: ergo:productname().
-type edge_id() :: integer().
-type batch_id() :: integer().
-type normalized_product() :: string().

-record(task,    { name :: taskname(), command :: [binary()]}).
-record(product, { name :: productname() }).
-record(next_id, { kind :: atom(), value :: integer() }).

-record(file_meta, {
          edge_id :: edge_id(), batch_id :: batch_id(), removed_id :: batch_id(),
          about :: normalized_product(), name :: atom(), value :: term() }).
-record(task_meta, {
          edge_id :: edge_id(), batch_id :: batch_id(), removed_id :: batch_id(),
          about :: taskname(), name :: atom(), value :: term() }).
-record(seq, {
          edge_id :: edge_id(), batch_id :: batch_id(), removed_id :: batch_id(), before :: taskname(), then :: taskname() }).
-record(cotask, {
          edge_id :: edge_id(), batch_id :: batch_id(), removed_id :: batch_id(), task :: taskname(), also :: taskname() }).
-record(production, {
          edge_id :: edge_id(), batch_id :: batch_id(), removed_id :: batch_id(), task :: taskname(), produces :: normalized_product() }).
-record(requirement, {
          edge_id :: edge_id(), batch_id :: batch_id(), removed_id :: batch_id(), task :: taskname(), requires :: normalized_product() }).
-record(dep, {
          edge_id :: edge_id(), batch_id :: batch_id(), removed_id :: batch_id(), from :: normalized_product(), to :: normalized_product() }).
-type edge_record() :: #seq{} | #cotask{} | #production{} | #dep{} | #requirement{} | #file_meta{} | #task_meta{}.

-record(provenence, { edge_id :: edge_id(), task :: taskname() }).
-record(edge_label, { from_edges :: [edge_id()] }).
-record(gen_edge,   { from :: taskname(), to :: taskname(), implied_by :: [edge_id()] }).

-record(state, { workspace :: ergo:workspace_name(),
                 workspace_root_re :: tuple(),
                 batch_id :: integer(),
                 removed_id :: integer(),
                 edges :: ets:tid(),
                 vertices :: ets:tid(),
                 provenence :: ets:tid()}).
