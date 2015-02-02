open Lwt
open Sexplib.Std
open Block_ring_unix
open Log

module type OP = sig
  type t

  val to_cstruct: t -> Cstruct.t
  val of_cstruct: Cstruct.t -> t
end

module Make(Op: OP) = struct

  type t = {
    p: Producer.t;
    c: Consumer.t;
    filename: string;
    cvar: unit Lwt_condition.t;
    mutable please_shutdown: bool;
    mutable shutdown_complete: bool;
    perform: Op.t -> unit Lwt.t;
  }

  let replay t =
    Consumer.fold ~f:(fun x y -> x :: y) ~t:t.c ~init:[] ()
    >>= function
    | `Error msg ->
       error "Error replaying the journal, cannot continue: %s" msg;
       Consumer.detach t.c
       >>= fun () ->
       fail (Failure msg)
    | `Ok (position, items) ->
       info "There are %d items in the journal to replay" (List.length items);
       Lwt_list.iter_p
         (fun item ->
           t.perform (Op.of_cstruct item)
         ) items
       >>= fun () ->
       ( Consumer.advance ~t:t.c ~position ()
         >>= function
         | `Error msg ->
           error "In replay, failed to advance consumer: %s" msg;
           fail (Failure msg)
         | `Ok () ->
           (* wake up anyone stuck in a `Retry loop *)
           Lwt_condition.broadcast t.cvar ();
           return () )

  let start filename perform =
    ( Consumer.attach ~disk:filename ()
      >>= function
      | `Error msg ->
        info "There is no journal on %s: no need to replay" filename;
        ( Producer.create ~disk:filename ()
          >>= function
          | `Error msg ->
            error "Failed to create empty journal on %s" filename;
            fail (Failure msg)
          | `Ok () ->
            ( Consumer.attach ~disk:filename ()
              >>= function
              | `Error msg ->
                error "Creating an empty journal failed on %s: %s" filename msg;
                fail (Failure msg)
              | `Ok c ->
                return c )
        )
      | `Ok x ->
        return x
    ) >>= fun c ->
    ( Producer.attach ~disk:filename ()
      >>= function
      | `Error msg ->
        error "Failed to open journal on %s: %s" filename msg;
        fail (Failure msg)
      | `Ok p ->
        return p
    ) >>= fun p ->
    let please_shutdown = false in
    let shutdown_complete = false in
    let cvar = Lwt_condition.create () in
    let t = { p; c; filename; please_shutdown; shutdown_complete; cvar; perform } in
    replay t
    >>= fun () ->
    (* Run a background thread processing items from the journal *)
    let (_: unit Lwt.t) =
      let rec forever () =
        Lwt_condition.wait t.cvar
        >>= fun () ->
        if t.please_shutdown then begin
          t.shutdown_complete <- true;
          Lwt_condition.broadcast t.cvar ();
          return ()
        end else begin
          replay t
          >>= fun () ->
          forever ()
        end in
      forever () in
    return t

  let shutdown t =
    t.please_shutdown <- true;
    let rec loop () =
      if t.shutdown_complete
      then return ()
      else
        Lwt_condition.wait t.cvar
        >>= fun () ->
        loop () in
    loop ()
    >>= fun () ->
    Consumer.detach t.c 

  let rec push t op =
    if t.please_shutdown
    then fail (Failure "journal shutdown in progress")
    else begin
      let item = Op.to_cstruct op in
      Producer.push ~t:t.p ~item ()
      >>= function
      | `Retry ->
         info "journal is full; waiting for a notification";
         Lwt_condition.wait t.cvar
         >>= fun () ->
         push t op
      | `TooBig ->
         error "journal is too small to receive item of size %d bytes" (Cstruct.len item);
         fail (Failure "journal too small")
      | `Error msg ->
         error "Failed to write item to journal: %s" msg;
         fail (Failure msg)
      | `Ok position ->
         ( Producer.advance ~t:t.p ~position ()
           >>= function
           | `Error msg ->
             error "Failed to advance producer pointer: %s" msg;
             fail (Failure msg)
           | `Ok () ->
             Lwt_condition.broadcast t.cvar ();
             return () )
    end
end
