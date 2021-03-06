(*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd
module F = Format
module L = Logging

module LocalAccessPath = struct
  type t = {access_path: AccessPath.t; parent: Typ.Procname.t} [@@deriving compare]

  let equal = [%compare.equal : t]

  let make access_path parent = {access_path; parent}

  let to_formal_option {access_path= ((_, base_typ) as base), accesses; parent} formal_map =
    match FormalMap.get_formal_index base formal_map with
    | Some formal_index ->
        Some (make ((Var.of_formal_index formal_index, base_typ), accesses) parent)
    | None ->
        None


  let pp fmt t = AccessPath.pp fmt t.access_path
end

module MethodCall = struct
  type t = {receiver: LocalAccessPath.t; procname: Typ.Procname.t} [@@deriving compare]

  let make receiver procname = {receiver; procname}

  let pp fmt {receiver; procname} =
    F.fprintf fmt "%a.%a" LocalAccessPath.pp receiver Typ.Procname.pp procname
end

module CallSet = AbstractDomain.FiniteSet (MethodCall)
include AbstractDomain.Map (LocalAccessPath) (CallSet)

let substitute ~(f_sub: LocalAccessPath.t -> LocalAccessPath.t option) astate =
  fold
    (fun original_access_path call_set acc ->
      let access_path' =
        match f_sub original_access_path with
        | Some access_path ->
            access_path
        | None ->
            original_access_path
      in
      let call_set' =
        CallSet.fold
          (fun ({procname} as call) call_set_acc ->
            let receiver =
              match f_sub call.receiver with Some receiver' -> receiver' | None -> call.receiver
            in
            CallSet.add {receiver; procname} call_set_acc )
          call_set CallSet.empty
      in
      add access_path' call_set' acc )
    astate empty


(** Unroll the domain to enumerate all the call chains ending in [call] and apply [f] to each
    maximal chain. For example, if the domain encodes the chains foo().bar().goo() and foo().baz(),
    [f] will be called once on foo().bar().goo() and once on foo().baz() *)
let iter_call_chains_with_suffix ~f call_suffix astate =
  let max_depth = cardinal astate in
  let rec unroll_call_ ({receiver; procname}: MethodCall.t) (acc, depth) =
    let acc' = procname :: acc in
    let depth' = depth + 1 in
    let is_cycle access_path =
      (* detect direct cycles and cycles due to mutual recursion *)
      LocalAccessPath.equal access_path receiver || depth' > max_depth
    in
    try
      let calls' = find receiver astate in
      CallSet.iter
        (fun call ->
          if not (is_cycle call.receiver) then unroll_call_ call (acc', depth')
          else f receiver.access_path acc' )
        calls'
    with Not_found -> f receiver.access_path acc'
  in
  unroll_call_ call_suffix ([], 0)


let iter_call_chains ~f astate =
  iter
    (fun _ call_set ->
      CallSet.iter (fun call -> iter_call_chains_with_suffix ~f call astate) call_set )
    astate
