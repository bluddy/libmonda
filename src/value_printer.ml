(***************************************************************************)
(*                                                                         *)
(*                 Make OCaml native debugging awesome!                    *)
(*                                                                         *)
(*                   Mark Shinwell, Jane Street Europe                     *)
(*                                                                         *)
(*  Copyright (c) 2013--2019 Jane Street Group, LLC                        *)
(*                                                                         *)
(*  Permission is hereby granted, free of charge, to any person obtaining  *)
(*  a copy of this software and associated documentation files             *)
(*  (the "Software"), to deal in the Software without restriction,         *)
(*  including without limitation the rights to use, copy, modify, merge,   *)
(*  publish, distribute, sublicense, and/or sell copies of the Software,   *)
(*  and to permit persons to whom the Software is furnished to do so,      *)
(*  subject to the following conditions:                                   *)
(*                                                                         *)
(*  The above copyright notice and this permission notice shall be         *)
(*  included in all copies or substantial portions of the Software.        *)
(*                                                                         *)
(*  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        *)
(*  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     *)
(*  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. *)
(*  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   *)
(*  CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   *)
(*  TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      *)
(*  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 *)
(*                                                                         *)
(***************************************************************************)

[@@@ocaml.warning "+a-4-30-40-41-42"]

module List = ListLabels
module Variant_kind = Type_oracle.Variant_kind

let debug = Monda_debug.debug

let optimized_out = "<unavailable>"

module Make (D : Debugger.S) (Cmt_cache : Cmt_cache_intf.S)
      (Type_helper : Type_helper_intf.S
        with module Cmt_cache := Cmt_cache
        with module D := D)
      (Type_printer : Type_printer_intf.S
        with module Cmt_cache := Cmt_cache) =
struct
  (* CR mshinwell: Remove "our" *)
  module Our_type_oracle = Type_oracle.Make (D) (Cmt_cache)
  module V = D.Value
  module Our_value_copier = Value_copier.Make (D)

  type t = {
    cmt_cache : Cmt_cache.t;
    type_oracle : Our_type_oracle.t;
    type_printer : Type_printer.t;
  }

  type operator =
    | Nothing
    | Separator
    | Application

  type state = {
    summary : bool;
    depth : int;
    max_depth : int;
    max_string_length : int;
    print_sig : bool;
    formatter : Format.formatter;
    max_array_elements_etc_to_print : int;
    only_print_short_type : bool;
    only_print_short_value : bool;
    operator_above : operator;
    visited : V.Set.t;
  }

  let descend state ~current_operator =
    { state with
      depth = state.depth + 1;
      print_sig = false;
      operator_above = current_operator;
    }

  let create cmt_cache type_printer =
    { type_oracle = Our_type_oracle.create ~cmt_cache;
      cmt_cache;
      type_printer;
    }

  let rec value_looks_like_list t value =
    if V.is_int value && V.int value = Some 0 (* nil *) then
      true
    else
      if (not (V.is_int value))
         && V.is_block value
         && V.tag_exn value = 0
         && V.size_exn value = 2
      then
        match V.field_exn value 1 with
        | None -> false
        | Some next -> value_looks_like_list t next
      else
        false

  let maybe_parenthesise state ~current_operator f =
    let needs_parentheses =
      match state.operator_above, current_operator with
      | Application, Application -> true
      | (Nothing | Separator | Application), _ -> false
    in
    let formatter = state.formatter in
    if needs_parentheses then begin
      Format.fprintf formatter "("
    end;
    f ();
    if needs_parentheses then begin
      Format.fprintf formatter ")"
    end

  let rec print_value t ~state ~type_of_ident:type_and_env v : unit =
    let formatter = state.formatter in
    let env =
      match type_and_env with
      | None -> None
      | Some (_ty, env, _is_parameter) -> Some env
    in
    let _is_parameter =
      match type_and_env with
      | None -> Is_parameter.local  (* this is conservative *)
      | Some (_ty, _env, is_parameter) -> is_parameter
    in
    let type_info =
      let type_and_env =
        match type_and_env with
        | None -> None
        | Some (ty, env, _is_parameter) -> Some (ty, env)
      in
      Our_type_oracle.find_type_information t.type_oracle ~formatter
        type_and_env ~scrutinee:v
    in
    if (state.summary && state.depth > 2)
        || state.depth > state.max_depth then begin
      Format.fprintf formatter "_"
    end else if V.Set.mem v state.visited then begin
      (* CR mshinwell: This is happening for normal sharing too *)
      Format.fprintf formatter "<circularity>"
    end else begin
      let state =
        { state with
          visited = V.Set.add v state.visited;
        }
      in
      match type_info with
      | Obj_immediate -> print_int t ~state v
      | Obj_immediate_but_should_be_boxed ->
        (* One common case: a value that is usually boxed but for the moment is
           initialized with [Val_unit].  For example: module fields before
           initializers have been run when using [Closure]. *)
        if V.int v = Some 0 then
          Format.fprintf formatter "@{<function_name_colour>()@}"
        else
          begin match V.raw v with
          | Some v -> Format.fprintf formatter "@{<error_colour>0x%nx}" v
          | None -> Format.fprintf formatter "<synthetic pointer>"
          end
      | Obj_boxed_traversable ->
        if state.summary then Format.fprintf formatter "..."
        else print_multiple_without_type_info t ~state v
      | Obj_boxed_not_traversable ->
        begin match V.raw v with
        | Some raw ->
          Format.fprintf formatter "@{<error_colour><0x%nx, tag %d>@}"
            raw (V.tag_exn v)
        | None -> Format.fprintf formatter "<synthetic pointer>"
        end
      | Unit -> Format.fprintf formatter "()"
      | Int ->
        begin match V.int v with
        | Some _ -> print_int t ~state v
        | None -> Format.fprintf formatter "@{<error_colour><Int?>@}"
        end
      | Char -> print_char t ~state v
      | Abstract path ->
        begin match env with
        | None ->
          Format.fprintf formatter "@{<address_colour><%s>@}" (Path.name path)
        | Some env ->
          Printtyp.wrap_printing_env ~error:false env (fun () ->
            Format.fprintf formatter "@{<address_colour><%a>@}"
              Printtyp.path path)
        end
      | Array (ty, env) -> print_array t ~state ~ty ~env v
      | List (ty, env) ->
        print_list t ~state
          ~ty_and_env:(Some (Cmt_file.Core ty, env, Is_parameter.local)) v
      | Ref (ty, env) -> print_ref t ~state ~ty ~env v
      | Tuple (tys, env) -> print_tuple t ~state ~tys ~env v
      | Constant_constructor (name, kind) ->
        print_constant_constructor t ~state ~kind ~name
      | Non_constant_constructor (path, ctor_decls, params,
            instantiated_params, env, kind) ->
        print_non_constant_constructor t ~state ~path ~ctor_decls ~params
            ~instantiated_params ~env ~kind v
      | Record (path, params, args, fields, record_repr, env) ->
        print_record t ~state ~path ~params ~args ~fields
            ~record_repr ~env v
      | Open -> Format.fprintf formatter "<value of open type>"
      | String -> print_string t ~state v
      | Float -> print_float t ~state v
      | Float_array -> print_float_array t ~state v
      | Closure -> print_closure t ~state ~scrutinee:v
      | Lazy -> Format.fprintf formatter "<lazy>"
      | Object -> Format.fprintf formatter "<object>"
      | Abstract_tag -> Format.fprintf formatter "<block with Abstract_tag>"
      | Format6 -> print_format6 t ~state v
      | Stdlib_set { env; element_ty; } ->
        print_stdlib_set t state env ~element_ty v
      | Stdlib_map { key_env; key_ty; datum_env; datum_ty; } ->
        print_stdlib_map t state ~key_env ~key_ty ~datum_env ~datum_ty v
      | Stdlib_hashtbl { key_env; key_ty; datum_env; datum_ty; } ->
        print_stdlib_hashtbl t state ~key_env ~key_ty ~datum_env ~datum_ty v
      | Custom -> print_custom_block t ~state v
      | Module mod_ty ->
        let env =
          match env with
          | None -> Env.empty
          | Some env -> env
        in
        print_module t state env mod_ty v
      | Unknown -> Format.fprintf formatter "unknown"
    end;
    if state.print_sig then begin
      match type_info with
      | Unit | Module _ -> ()
      | _ ->
        let (_type_printed : bool) =
          Type_printer.print_given_type_and_env formatter type_and_env
        in
        ()
    end

  and print_multiple_without_type_info t ~state value =
    let formatter = state.formatter in
    (* If a value, that cannot be identified sensibly from its type,
       looks like a (non-empty) list then we assume it is such.  It seems
       more likely than a set of nested pairs. *)
    if value_looks_like_list t value then begin
      if state.summary then
        Format.fprintf formatter "@{<error_colour>[...]?@}"
      else begin
        print_list t ~state ~ty_and_env:None value;
        Format.fprintf formatter "@{<error_colour>?@}"
      end
    end else begin
      let need_outer_box =
        match state.operator_above with
        | Nothing -> false
        | _ -> true
      in
      if need_outer_box then begin
        Format.fprintf formatter "@[<hov 2>"
      end;
      Format.fprintf formatter
        "@{<error_colour>[@}@{<variable_name_colour>tag %d:@} "
        (V.tag_exn value);
      let original_size = V.size_exn value in
      let max_size =
        if state.summary then 2 else state.max_array_elements_etc_to_print
      in
      let size, truncated =
        if original_size > max_size then max_size, true
        else original_size, false
      in
      for field = 0 to size - 1 do
        if field > 0 then begin
          Format.fprintf formatter "@{<error_colour>;@}@ "
        end;
        match V.field_exn value field with
        | None -> Format.fprintf formatter "%s" optimized_out
        | Some field_value ->
          let state = descend state ~current_operator:Separator in
          Format.fprintf formatter "@{<error_colour>";
          print_value t ~state ~type_of_ident:None field_value;
          Format.fprintf formatter "@}"
        | exception D.Read_error ->
          Format.fprintf formatter "@{<error_colour><field %d read failed>@}"
            field
      done;
      if truncated then begin
        Format.fprintf formatter " <%d elements follow>"
          (original_size - max_size)
      end;
      Format.fprintf formatter "@{<error_colour>]@}";
      if need_outer_box then begin
        Format.fprintf formatter "@]"
      end
    end

  and print_multiple_with_type_info ?print_prefix _t ~state ~printers
        ~current_operator ~opening_delimiter ~separator ~closing_delimiter
        ~spaces_inside_delimiters ~can_elide_delimiters
        ~break_after_opening_delimiter value =
    let formatter = state.formatter in
    let original_size = V.size_exn value in
    let max_size =
      if state.summary then 2 else state.max_array_elements_etc_to_print
    in
    let size, truncated =
      if original_size > max_size then max_size, true
      else original_size, false
    in
    let indent =
      String.length opening_delimiter
        + (if spaces_inside_delimiters then 1 else 0)
    in
    let need_outer_box =
      match state.operator_above with
      | Nothing -> false
      | _ -> true
    in
    if need_outer_box then begin
      Format.pp_open_hovbox formatter indent
    end;
    begin match print_prefix with
    | None -> ()
    | Some print_prefix -> print_prefix formatter ()
    end;
    let elide_delimiters = can_elide_delimiters && size = 1 in
    if not elide_delimiters then begin
      Format.fprintf formatter "%s" opening_delimiter;
      if spaces_inside_delimiters then begin
        Format.fprintf formatter "@ "
      end;
      if break_after_opening_delimiter && size > 0 then begin
        Format.fprintf formatter "@,"
      end
    end;
    for field = 0 to size - 1 do
      if field > 0 then begin
        Format.fprintf formatter "%s@ " separator
      end;
      match V.field_exn value field with
      | None -> Format.fprintf formatter "%s" optimized_out
      | Some field_value ->
        let state = descend state ~current_operator in
        printers.(field) state field_value
      | exception D.Read_error ->
        Format.fprintf formatter "@{<error_colour><field %d read failed>@}"
          field
    done;
    if truncated then begin
      Format.fprintf formatter "%s@ <%d elements follow>" separator
        (original_size - max_size)
    end;
    if not elide_delimiters then begin
      if spaces_inside_delimiters && size > 1 then begin
        Format.fprintf formatter "@ "
      end;
      Format.fprintf formatter "%s" closing_delimiter
    end;
    if need_outer_box then begin
      Format.fprintf formatter "@]"
    end

  and print_int _t ~state v =
    let formatter = state.formatter in
    match V.int v with
    | None -> Format.fprintf formatter "<synthetic pointer>"
    | Some v ->
      if v = Stdlib.min_int then
        Format.fprintf formatter "@{<variable_name_colour>Stdlib.min_int@}"
      else if v = Stdlib.max_int then
        Format.fprintf formatter "@{<variable_name_colour>Stdlib.max_int@}"
      else
        Format.fprintf formatter "%d" v

  and print_char _t ~state v =
    let formatter = state.formatter in
    match V.int v with
    | None -> Format.fprintf formatter "<synthetic pointer>"
    | Some value ->
      if value >= 0 && value <= 255 then
        Format.fprintf formatter "'%s'" (Char.escaped (Char.chr value))
      else
        match V.raw v with
        | Some v -> Format.fprintf formatter "%nd" v
        | None -> Format.fprintf formatter "<synthetic pointer>"

  and print_string _t ~state v =
    let formatter = state.formatter in
    let s = V.string v in
    if String.length s > state.max_string_length then
      Format.fprintf formatter "%S (* %d chars follow *)"
        (String.sub s 0 state.max_string_length)
        (String.length s - state.max_string_length)
    else
      Format.fprintf formatter "%S" (V.string v)

  and print_tuple t ~state ~tys ~env v =
    let component_types = Array.of_list tys in
    let size_ok = Array.length component_types = V.size_exn v in
    let printers =
      Array.map (fun ty state v ->
          let type_of_ident =
            if size_ok then Some (Cmt_file.Core ty, env, Is_parameter.local)
            else None
          in
          print_value t ~state ~type_of_ident v)
        component_types
    in
    print_multiple_with_type_info t ~state ~printers
      ~current_operator:Separator
      ~opening_delimiter:"(" ~separator:"," ~closing_delimiter:")"
      ~spaces_inside_delimiters:false ~can_elide_delimiters:true
      ~break_after_opening_delimiter:false
      v

  and print_array t ~state ~ty ~env v =
    let size = V.size_exn v in
    let printers =
      Array.init size (fun _ty state v ->
        let type_of_ident = Some (Cmt_file.Core ty, env, Is_parameter.local) in
        print_value t ~state ~type_of_ident v)
    in
    print_multiple_with_type_info t ~state ~printers
      ~current_operator:Separator
      ~opening_delimiter:"[|" ~separator:";" ~closing_delimiter:"|]"
      ~spaces_inside_delimiters:true ~can_elide_delimiters:false
      ~break_after_opening_delimiter:false
      v

  and print_list t ~state ~ty_and_env v : unit =
    let formatter = state.formatter in
    let print_element =
      let state = descend state ~current_operator:Separator in
      print_value t ~state ~type_of_ident:ty_and_env
    in
    let max_elements =
      if state.summary then 2 else state.max_array_elements_etc_to_print
    in
    let rec aux v ~element_index =
      if V.is_block v then begin
        if element_index >= max_elements then
          Format.fprintf formatter "..."
        else begin
          try
            begin match V.field_exn v 0 with
            | None -> Format.fprintf formatter "<list element unavailable>"
            | Some elt -> print_element elt
            end;
            begin match V.field_exn v 1 with
            | None ->
              Format.fprintf formatter ";@ <list next pointer unavailable>"
            | Some next ->
              if V.is_block next then Format.fprintf formatter ";@ ";
              aux next ~element_index:(element_index + 1)
            end;
          with D.Read_error ->
            Format.fprintf formatter "<list element read failed>"
        end
      end
    in
    let need_outer_box =
      match state.operator_above with
      | Nothing -> false
      | _ -> true
    in
    if need_outer_box then begin
      Format.fprintf formatter "@[<hov 1>"
    end;
    Format.fprintf formatter "[";
    aux v ~element_index:0;
    Format.fprintf formatter "]";
    if need_outer_box then begin
      Format.fprintf formatter "@]"
    end

  and print_ref t ~state ~ty ~env v =
    let formatter = state.formatter in
    let current_operator : operator = Application in
    maybe_parenthesise state ~current_operator (fun () ->
      Format.fprintf formatter "@{<function_name_colour>ref@} ";
      match V.field_exn v 0 with
      | None -> Format.fprintf formatter "%s" optimized_out
      | Some contents ->
        let state = descend state ~current_operator in
        print_value t ~state
          ~type_of_ident:(Some (Cmt_file.Core ty, env, Is_parameter.local))
          contents)

  and print_record t ~state ~path:_ ~params ~args ~fields ~record_repr ~env v =
    let formatter = state.formatter in
    if state.summary then
      Format.fprintf formatter "{...}"
    else if List.length fields <> V.size_exn v then
      Format.fprintf formatter
        "{@{<error_colour><expected %d fields, target has %d>@}}"
        (List.length fields) (V.size_exn v)
    else begin
      let fields = Array.of_list fields in
      let type_for_field ~index =
        begin match record_repr with
        | Types.Record_float -> Predef.type_float
        | Types.Record_regular ->
          let field_type = fields.(index).Types.ld_type in
          begin try Ctype.apply env params field_type args
          with Ctype.Cannot_apply -> field_type
          end
        | Types.Record_extension
        | Types.Record_inlined _
        | Types.Record_unboxed _ ->
          (* CR mshinwell: fix this *)
          Predef.type_int
        end
      in
      let fields_helpers =
        Array.mapi (fun index ld ->
            let typ = type_for_field ~index in
            let printer v =
              let state = descend state ~current_operator:Separator in
              print_value t ~state
                ~type_of_ident:(Some (
                  Cmt_file.Core typ, env, Is_parameter.local))
                v
            in
            Ident.name ld.Types.ld_id, printer)
          fields 
      in
      if state.depth = 0 && Array.length fields > 1 then begin
        Format.pp_print_newline formatter ();
        Format.fprintf formatter "@[<v 2>  "
      end;
      let nb_fields = V.size_exn v in
      Format.fprintf formatter "@[<hv 0>{ ";
      Format.fprintf formatter "@[<hv 0>";
      for field_nb = 0 to nb_fields - 1 do
        if field_nb > 0 then Format.fprintf formatter "@ ";
        try
          let (field_name, printer) = fields_helpers.(field_nb) in
          Format.fprintf formatter "@[<hov 2>@{<variable_name_colour>%s@}@ =@ "
            field_name;
          match V.field_exn v field_nb with
          | None ->
            Format.fprintf formatter "%s" optimized_out;
            Format.fprintf formatter ";@]"
          | Some v ->
            printer v;
            Format.fprintf formatter ";@]"
        with D.Read_error ->
          Format.fprintf formatter "@{<error_colour><could not read field %d>}"
            field_nb
      done;
      Format.fprintf formatter "@]@;}@]";
      if state.depth = 0 && Array.length fields > 1 then begin
        Format.fprintf formatter "@]"
      end
    end

  and print_closure _t ~state ~scrutinee:v =
    let formatter = state.formatter in
    try
      if state.summary then
        Format.fprintf formatter "<fun>"
      else begin
        match V.field_exn v 1 with
        | None -> Format.fprintf formatter "<fun (code pointer unavailable)>"
        | Some pc ->
          let pc = V.int pc in
          let partial, pc =
            match pc with
            | None -> None, V.field_as_addr_exn v 0
            | Some arity ->
              if arity < 2 then
                None, V.field_as_addr_exn v 0
              else
                let partial_app_pc = V.field_as_addr_exn v 0 in
                let pc = V.field_as_addr_exn v 2 in
                (* Try to determine if the closure corresponds to a
                   partially-applied function. *)
                match D.symbol_at_pc partial_app_pc with
                | None -> None, pc
                | Some symbol ->
                  match Naming_conventions.is_currying_wrapper symbol with
                  | None -> None, pc
                  | Some (total_num_args, num_args_so_far) ->
                    (* Find the original closure in order to determine which
                       function is partially applied.  (See comments about
                       currying functions in cmmgen.ml in the compiler
                       source.) *)
                    match begin
                      let v = ref v in
                      for _i = 1 to num_args_so_far do
                        if V.size_exn !v <> 5 then raise Exit;
                        match V.field_exn !v 4 with
                        | None -> raise Exit
                        | Some new_v -> v := new_v
                      done;
                      !v
                    end with
                    | exception Exit -> None, pc
                    | v ->
                      (* This should be the original function. *)
                      match V.field_exn v 1 with
                      | None -> None, pc
                      | Some arity ->
                        match V.int arity with
                        | None -> None, pc
                        | Some arity when arity <= 1 ->
                          (* The function should have more than 1 arg. *)
                          None, pc
                        | Some _arity ->
                          Some (total_num_args, num_args_so_far),
                            V.field_as_addr_exn v 2
          in
          let partial, partial', partial_args =
            match partial with
            | None -> "", "", ""
            | Some (total_num_args, args_so_far) ->
              "partial ", "partially-applied ",
                Printf.sprintf " (got %d of %d args)" args_so_far total_num_args
          in
          begin match D.symbol_at_pc pc with
          | None ->
            Format.fprintf formatter "<%sfun> (%a)%s" partial
              D.Target_memory.print_addr pc partial_args
          | Some symbol ->
            Format.fprintf formatter "%s@{<function_name_colour>%s@}%s"
              partial' symbol partial_args
          end

(*
          match
            D.filename_and_line_number_of_pc pc
              ~use_previous_line_number_if_on_boundary:true
          with
          | None ->
            begin match D.symbol_at_pc pc with
            | None ->
              Format.fprintf formatter "<%sfun> (%a)%s" partial
                D.Target_memory.print_addr pc partial_args
            | Some symbol ->
              Format.fprintf formatter "<%sfun> (%s)%s" partial
                symbol partial_args
            end
          | Some (filename, Some line) ->
            Format.fprintf formatter "<%sfun> (%s:%d)%s" partial filename line
              partial_args
          | Some (filename, None) ->
            Format.fprintf formatter "<%sfun> (%s, %a)%s" partial filename
              D.Target_memory.print_addr pc partial_args
*)
      end
    with D.Read_error -> Format.fprintf formatter "<closure?>"

  and print_constant_constructor _t ~state ~kind ~name =
    let formatter = state.formatter in
    Format.fprintf formatter "@{<function_name_colour>%s%s@}"
      (Variant_kind.to_string_prefix kind) name

  and print_non_constant_constructor t ~state ~path:_ ~ctor_decls ~params
        ~instantiated_params ~env ~kind v =
    let formatter = state.formatter in
    let kind = Variant_kind.to_string_prefix kind in
    if debug then begin
      List.iter params ~f:(fun ty ->
        Format.fprintf formatter "param>>";
        Printtyp.reset_and_mark_loops ty;
        Printtyp.type_expr formatter ty;
        Format.fprintf formatter "<<");
      List.iter instantiated_params ~f:(fun ty ->
        Format.fprintf formatter "iparam>>";
        Printtyp.reset_and_mark_loops ty;
        Printtyp.type_expr formatter ty;
        Format.fprintf formatter "<<")
    end;
    let non_constant_ctors, _ =
      List.fold_left ctor_decls
        ~init:([], 0)
        ~f:(fun (non_constant_ctors, next_ctor_number) ctor_decl ->
              let ident = ctor_decl.Types.cd_id in
              match ctor_decl.Types.cd_args with
              | Cstr_tuple [] -> non_constant_ctors, next_ctor_number
              | Cstr_tuple arg_tys ->
                (* CR mshinwell: check [return_type] is just that, and use it.
                   Presumably for GADTs. *)
                (next_ctor_number,
                  (ident, arg_tys))::non_constant_ctors,
                  next_ctor_number + 1
              | Cstr_record label_decls ->
                let arg_tys =
                  List.map label_decls
                    ~f:(fun (label_decl : Types.label_declaration) ->
                      label_decl.ld_type)
                in
                (next_ctor_number,
                  (ident, arg_tys))::non_constant_ctors,
                  next_ctor_number + 1)
    in
    let ctor_info =
      let tag = V.tag_exn v in
      try Some (List.assoc tag non_constant_ctors) with Not_found -> None
    in
    begin match ctor_info with
    | None -> print_multiple_without_type_info t ~state v
    | Some (cident, args) ->
      let current_operator : operator = Application in
      maybe_parenthesise state ~current_operator (fun () ->
        if state.summary then begin
          Format.fprintf formatter "%s%s (...)" kind (Ident.name cident)
        end else if List.length args <> V.size_exn v then begin
          Format.fprintf formatter
            "@[%s%s (@{<error_colour><arg count mismatch, expected %d, \
              heap value has %d>@})@]"
            kind (Ident.name cident)
            (List.length args)
            (V.size_exn v)
        end else begin
          let printers =
            let args = Array.of_list args in
            Array.map (fun arg_ty state v ->
                let arg_ty =
                  try Ctype.apply env params arg_ty instantiated_params
                  with Ctype.Cannot_apply -> arg_ty
                in
                print_value t ~state
                  ~type_of_ident:(Some (
                    Cmt_file.Core arg_ty, env, Is_parameter.local))
                  v)
              args
          in
          let print_prefix ppf () =
            let name = Ident.name cident in
            Format.fprintf ppf "@{<function_name_colour>%s%s@}@ " kind name
          in
          print_multiple_with_type_info ~print_prefix t ~state ~printers
            ~current_operator
            ~opening_delimiter:"(" ~separator:"," ~closing_delimiter:")"
            ~spaces_inside_delimiters:false ~can_elide_delimiters:true
            ~break_after_opening_delimiter:false
            v
        end)
    end

  and print_float _t ~state v =
    let formatter = state.formatter in
    try Format.fprintf formatter "%f" (V.float_field_exn v 0)
    with D.Read_error -> Format.fprintf formatter "<double read failed>"

  and print_float_array _t ~state v =
    let formatter = state.formatter in
    let size = V.size_exn v in
    if size = 0 then Format.fprintf formatter "@[[| |] (* float array *)@]"
    else if state.summary then Format.fprintf formatter "@[[|...|]@]"
    else begin
      (* CR mshinwell: Should use [print_multiple_with_type_info] *)
      Format.fprintf formatter "@[<1>[| ";
      for i = 0 to size - 1 do
        Format.fprintf formatter "%f" (V.float_field_exn v i);
        if i < size - 1 then Format.fprintf formatter ";@;<1 0>"
      done;
      Format.fprintf formatter " |] (* float array *)@]"
    end

  and print_format6 _t ~state v =
    if debug then begin
      Printf.printf "print_format6\n"
    end;
    let formatter = state.formatter in
    let format_string : _ format6 = Our_value_copier.copy v in
    Format.fprintf formatter "%S" (string_of_format format_string)

  and print_custom_block _t ~state v =
    let formatter = state.formatter in
    if V.size_exn v < 2 then
      Format.fprintf formatter "<malformed custom block>"
    else
      match V.field_exn v 0 with
      | None ->
        Format.fprintf formatter "<custom block; ops pointer unavailable>"
      | Some custom_ops ->
        let identifier = V.c_string_field_exn custom_ops 0 in
        let data_ptr = V.field_as_addr_exn v 1 in
        let integer ~suffix =
          match V.field_exn v 1 with
          | None ->
            Format.fprintf formatter "<Int32.t (unavailable)>"
          | Some i ->
            match V.raw i with
            | None -> Format.fprintf formatter "<Int32.t (unavailable)>"
            | Some i -> Format.fprintf formatter "%nd%c" i suffix
        in
        match Naming_conventions.examine_custom_block_identifier identifier with
        | Bigarray ->
          Format.fprintf formatter "<Bigarray: data at %a>"
            D.Target_memory.print_addr data_ptr
        | Systhreads_mutex ->
          Format.fprintf formatter "<Mutex.t %a> (* systhreads *)"
            D.Target_memory.print_addr data_ptr
        | Systhreads_condition ->
          Format.fprintf formatter "<Condition.t %a> (* systhreads *)"
            D.Target_memory.print_addr data_ptr
        | Int32 -> integer ~suffix:'l'
        | Int64 -> integer ~suffix:'L'
        | Nativeint -> integer ~suffix:'n'
        | Channel ->
          (* CR mshinwell: use a better means of retrieving the fd *)
          Format.fprintf formatter "<channel on fd %Ld>"
            (D.Target_memory.read_int64_exn data_ptr)
        | Unknown ->
          Format.fprintf formatter "<custom block '%s' pointing at %a>"
            identifier
            D.Target_memory.print_addr data_ptr

  and print_stdlib_set t state env ~element_ty v =
    let formatter = state.formatter in
    if state.summary then begin
      Format.fprintf formatter "{...}"
    end else begin
      Format.fprintf formatter
        "@[<hov 2>@{<function_name_colour>Stdlib.Set@} { ";
      let first = ref true in
      let malformed () =
        first := false;
        Format.fprintf formatter " @{<error_colour><malformed>@}"
      in
      let one_elt_unavailable () =
        first := false;
        Format.fprintf formatter
          " @{<error_colour><one element unavailable>@}"
      in
      let one_or_more_elts_unavailable () =
        first := false;
        Format.fprintf formatter
          " @{<error_colour><one or more elements unavailable>@}"
      in
      let elt_state = descend state ~current_operator:Separator in
      (* The type definition from stdlib/set.ml is:
         type t = Empty | Node of {l:t; v:elt; r:t; h:int}
      *)
      let rec print v =
        if not !first then begin
          (* CR mshinwell: This prints extraneous commas *)
          Format.fprintf formatter ",@ "
        end;
        if V.is_int v then begin
          match V.int v with
          | Some 0 -> ()  (* [Empty] *)
          | _ -> malformed ()
        end else begin
          match V.tag_exn v with
          | 0 ->  (* [Node] *)
            begin match V.size_exn v with
            | 4 ->
              begin match V.field_exn v 0 with
              | exception _ -> one_or_more_elts_unavailable ()
              | None -> one_or_more_elts_unavailable ()
              | Some left -> print left
              end;
              first := false;
              begin match V.field_exn v 1 with
              | exception _ -> one_elt_unavailable ()
              | None -> one_elt_unavailable ()
              | Some elt ->
                print_value t ~state:elt_state
                  ~type_of_ident:(Some (
                    Cmt_file.Core element_ty, env, Is_parameter.local))
                  elt
              end;
              begin match V.field_exn v 2 with
              | exception _ -> one_or_more_elts_unavailable ()
              | None -> one_or_more_elts_unavailable ()
              | Some right -> print right
              end
            | _ -> malformed ()
            end
          | _ -> malformed ()
        end
      in
      print v;
      if not !first then begin
        Format.fprintf formatter " "
      end;
      Format.fprintf formatter "}@]"
    end

  and print_stdlib_map t state ~key_env ~key_ty ~datum_env ~datum_ty v =
    let formatter = state.formatter in
    if state.summary then begin
      Format.fprintf formatter "{...}"
    end else if V.is_int v && V.int v = Some 0 then begin
      Format.fprintf formatter "(empty map)"
    end else begin
      Format.fprintf formatter
        "@[<hv 0>@[<hv 2>@{<function_name_colour>Stdlib.Map@} {@ ";
(*
      Format.fprintf formatter "@[<hv 0>";
*)
(*
      Format.pp_open_tbox formatter ();
      Format.pp_set_tab formatter ();
      Format.fprintf formatter "| key                           ";
      Format.pp_set_tab formatter ();
      Format.fprintf formatter "| value";
      Format.pp_force_newline formatter ();
(*      Format.pp_print_tab formatter ();*)
      let next_row () =
        Format.pp_force_newline formatter ()
      in
      let rule = "------------------------------" in
      let rule_off () =
        Format.fprintf formatter "%s%s" rule rule;
        next_row ()
      in
      rule_off ();
*)
      let next_row () = () in
      let malformed () =
        Format.fprintf formatter " @{<error_colour><malformed>@}";
        next_row ()
      in
      let min_num_bindings = ref 0 in
      let one_binding_unavailable () =
        incr min_num_bindings;
        Format.fprintf formatter
          " @{<error_colour><one binding unavailable>@}";
        next_row ()
      in
      let one_or_more_bindings_unavailable () =
        incr min_num_bindings;
        Format.fprintf formatter
          " @{<error_colour><one or more bindings unavailable>@}";
        next_row ()
      in
      let binding_state = descend state ~current_operator:Separator in
(*      let first = ref true in *)
      (* The type definition from stdlib/map.ml is:
         type 'a t = Empty | Node of {l:'a t; v:key; d:'a; r:'a t; h:int}
      *)
      let rec print v =
        if V.is_int v then begin
          match V.int v with
          | Some 0 -> ()  (* [Empty] *)
          | _ -> malformed ()
        end else begin
          match V.tag_exn v with
          | 0 ->  (* [Node] *)
            begin match V.size_exn v with
            | 5 ->
              begin match V.field_exn v 0 with
              | exception _ -> one_or_more_bindings_unavailable ()
              | None -> one_or_more_bindings_unavailable ()
              | Some left -> print left
              end;
              begin match V.field_exn v 1 with
              | exception _ -> one_binding_unavailable ()
              | None -> one_binding_unavailable ()
              | Some key ->
                match V.field_exn v 2 with
                | exception _ -> one_binding_unavailable ()
                | None -> one_binding_unavailable ()
                | Some datum ->
                  if !min_num_bindings > 0 then begin
                    Format.fprintf formatter "@ "
                  end;
                  incr min_num_bindings;
(*
                  let original_margin = Format.pp_get_margin formatter () in
                  Format.pp_set_margin formatter (String.length rule - 2);
                  Format.fprintf formatter "| ";
                  Format.fprintf formatter "@[<v 0>";
*)
                  Format.fprintf formatter "@[<hov 2>";
                  print_value t ~state:binding_state
                    ~type_of_ident:(Some (
                      Cmt_file.Core key_ty, key_env, Is_parameter.local))
                    key;
                  Format.fprintf formatter " @{<file_name_colour>==>@}@ ";
(*
                  Format.fprintf formatter "@]";
                  Format.pp_set_margin formatter original_margin;
*)
(*
                  Format.pp_print_tab formatter ();
                  Format.fprintf formatter "@]| ";
*)
(*
                  let original_margin = Format.pp_get_margin formatter () in
                  Format.fprintf formatter "@[<hov 2>";
                  Format.pp_set_margin formatter (String.length rule - 2);
*)
                  print_value t ~state:binding_state
                    ~type_of_ident:(Some (
                      Cmt_file.Core datum_ty, datum_env, Is_parameter.local))
                    datum;
                  Format.fprintf formatter ";@]";
(*
                  Format.fprintf formatter "@]";
                  Format.pp_set_margin formatter original_margin;
                  Format.pp_print_tab formatter ()
*)
              end;
              begin match V.field_exn v 3 with
              | exception _ -> one_or_more_bindings_unavailable ()
              | None -> one_or_more_bindings_unavailable ()
              | Some right -> print right
              end
            | _ -> malformed ()
            end
          | _ -> malformed ()
        end
      in
      print v;
(*
      if !min_num_bindings > 1 then begin
        Format.fprintf formatter " "
      end;
*)
(*
      rule_off ();
      Format.pp_close_tbox formatter ()
*)
      Format.fprintf formatter "@]@;@]}";
    end

  and print_stdlib_hashtbl t state ~key_env ~key_ty ~datum_env ~datum_ty v =
    let formatter = state.formatter in
    (* The type definitions from stdlib/hashtbl.ml are:

       type ('a, 'b) t =
         { mutable size: int;
           mutable data: ('a, 'b) bucketlist array;
           mutable seed: int;
           mutable initial_size: int;
         }

       and ('a, 'b) bucketlist =
           Empty
         | Cons of { mutable key: 'a;
                     mutable data: 'b;
                     mutable next: ('a, 'b) bucketlist }
    *)
    let binding_state = descend state ~current_operator:Separator in
    let first = ref true in
    let rec print_bucket_list bucket_list =
      if V.is_int bucket_list then
        match V.int bucket_list with
        | Some 0 ->  (* [Empty] *)
          ()
        | _ ->
          Format.fprintf formatter
            "@{<error_colour>}<bucket list malformed>"
      else
        match V.tag_exn bucket_list with
        | exception _ ->
          Format.fprintf formatter
            "@{<error_colour>}<bucket list tag read failed>"
        | 0 ->  (* [Cons] *)
          begin match V.size_exn bucket_list with
          | exception _ ->
            Format.fprintf formatter
              "@{<error_colour>}<bucket list size read failed>"
          | 3 ->
            if not !first then begin
              Format.fprintf formatter "@ ";
            end;
            first := false;
            Format.fprintf formatter "@[<hov 2>";
            begin match V.field_exn bucket_list 0 with
            | exception Not_found ->
              Format.fprintf formatter "@{<error_colour>}<key read failed>"
            | None ->
              Format.fprintf formatter "@{<error_colour>}<key unavailable>"
            | Some key ->
              print_value t ~state:binding_state
                ~type_of_ident:(Some (
                  Cmt_file.Core key_ty, key_env, Is_parameter.local))
                key
            end;
            Format.fprintf formatter " @{<file_name_colour>==>@}@ ";
            begin match V.field_exn bucket_list 1 with
            | exception Not_found ->
              Format.fprintf formatter "@{<error_colour>}<datum read failed>"
            | None ->
              Format.fprintf formatter "@{<error_colour>}<datum unavailable>"
            | Some datum ->
              print_value t ~state:binding_state
                ~type_of_ident:(Some (
                  Cmt_file.Core datum_ty, datum_env, Is_parameter.local))
                datum
            end;
            Format.fprintf formatter "@]";
            begin match V.field_exn bucket_list 2 with
            | exception Not_found ->
              Format.fprintf formatter "@{<error_colour>}<next read failed>"
            | None ->
              Format.fprintf formatter "@{<error_colour>}<next unavailable>"
            | Some next ->
              print_bucket_list next
            end;
          | _size ->
            Format.fprintf formatter
              "@{<error_colour>}<bucket list has wrong size>"
          end
        | _tag ->
          Format.fprintf formatter
            "@{<error_colour>}<bucket list has wrong tag>"
    in
    if state.summary then begin
      Format.fprintf formatter "{...}"
    end else begin
      if not (V.is_block v) then begin
        Format.fprintf formatter
          "@{<error_colour><malformed Stdlib.Hashtbl (not a block)>@}"
      end else begin
        match V.tag_exn v with
        | 0 ->
          begin match V.size_exn v with
          | 4 ->
            begin match V.field_exn v 1 with
            | exception _ ->
              Format.fprintf formatter
                "@{<error_colour><Stdlib.Hashtbl (target read failed)>@}"
            | None ->
              Format.fprintf formatter
                "@{<error_colour><Stdlib.Hashtbl (unavailable)>@}"
            | Some data ->
              Format.fprintf formatter
                "@[<hv 0>@{<function_name_colour>Stdlib.Hashtbl@} { ";
              Format.fprintf formatter "@[<hv 0>";
              begin match V.size_exn data with
              | exception _ ->
                Format.fprintf formatter
                  "@{<error_colour><Stdlib.Hashtbl (target read failed \
                    on size)>@}"
              | size ->
                for data_index = 0 to size - 1 do
                  match V.field_exn data data_index with
                  | exception _ ->
                    Format.fprintf formatter
                      "@{<error_colour>}<bucket list read failed>"
                  | None ->
                    Format.fprintf formatter
                      "@{<error_colour>}<bucket list unavailable>"
                  | Some bucket_list ->
                    print_bucket_list bucket_list
                done
              end;
              Format.fprintf formatter "@]@;}@]"
            end
          | _ ->
            Format.fprintf formatter
              "@{<error_colour><malformed Stdlib.Hashtbl (wrong size)>@}"
          end
        | _ ->
          Format.fprintf formatter
            "@{<error_colour><malformed Stdlib.Hashtbl (wrong tag)>@}"
      end
    end

  and print_module t state env (mod_ty : Types.module_type) v =
    let formatter = state.formatter in
    let sg =
      match mod_ty with
      | Mty_signature sg -> Some sg
      | Mty_ident _
      | Mty_functor _
      | Mty_alias _ -> None
    in
    match state.summary, sg with
    | true, _
    | _, None ->
      Format.fprintf formatter "<module block>"
    | _, Some sg ->
      assert (V.is_block v);  (* checked in [Type_oracle] *)
      let actual_module_block_size = V.size_exn v in
      if state.depth = 0 && actual_module_block_size > 1 then begin
        Format.pp_print_newline formatter ();
        Format.fprintf formatter "@[<v 2>  "
      end;
      Format.fprintf formatter "@[<hv 2>struct@ ";
      (* CR mshinwell: Work out how to refactor [Printtyp] so we don't need
         to expose so many functions there. *)
      let rec print_sig_items ~pos ~first ~in_type_group env
            (sig_items : Types.signature_item list) =
        match sig_items with
        | [] -> ()
        | (sig_item::sig_items) as sig_items' ->
          let in_type_group =
            Printtyp.still_in_type_group env in_type_group sig_item
          in
          let sg, sig_items = Printtyp.filter_rem_sig sig_item sig_items in
          Printtyp.hide_rec_items sig_items';
          Printtyp.protect_rec_items sig_items';
          Printtyp.reset_naming_context ();
          let env = Env.add_signature (sig_item :: sg) env in
          let pos, first =
            match pos with
            | None -> None, first
            | Some pos ->
              if pos >= actual_module_block_size then begin
                Format.fprintf formatter "@{<error_colour><module block at %a \
                    has %d fields but expected at least %d>}"
                  V.print v
                  actual_module_block_size
                  (pos + 1);
                None, first
              end else begin
                if not first then begin
                  Format.fprintf formatter "@;"
                end;
                let print_ident ?(print_type = fun _ppf () -> ()) what ident =
                  Format.fprintf formatter
                    "@[<hov 2>%s @{<variable_name_colour>%s@}%a@ =@ "
                    what
                    (Ident.name ident)
                    print_type ()
                in
                (* CR mshinwell: improve this (maybe add address printing as
                   an option to the normal boxed value printer?) *)
                let print_field_raw () =
                  try
                    match V.field_exn v pos with
                    | None ->
                      Format.fprintf formatter "%s" optimized_out
                    | Some v ->
                      Format.fprintf formatter "%a" V.print v
                  with D.Read_error ->
                    Format.fprintf formatter
                      "@{<error_colour><could not read field %d \
                        of module block>}"
                      pos
                in
                let print_field ty =
                  try
                    match V.field_exn v pos with
                    | None ->
                      Format.fprintf formatter "%s" optimized_out
                    | Some v ->
                      let state = descend state ~current_operator:Separator in
                      let type_of_ident =
                        match ty with
                        | None -> None
                        | Some ty -> Some (ty, env, Is_parameter.local)
                      in
                      print_value t ~state ~type_of_ident v
                  with D.Read_error ->
                    Format.fprintf formatter
                      "@{<error_colour><could not read field %d \
                        of module block>}"
                      pos
                in
                let next_pos =
                  match sig_item with
                  | Sig_value (ident, { val_type; val_kind; _ }) ->
                    print_ident ~print_type:(fun formatter () ->
                        Format.fprintf formatter "@ : @{<type_colour>%a@}"
                        Printtyp.type_scheme val_type)
                      "let" ident;
                    let ty : Cmt_file.core_or_module_type = Core val_type in
                    print_field (Some ty);
                    begin match val_kind with
                    | Val_prim _ -> pos
                    | _ -> pos + 1
                    end
                  | Sig_typext (ident, ctor_decl, _) ->
                    Format.fprintf formatter
                      "@[<hov 2>@{<type_colour>%a@} = "
                      (Printtyp.extension_constructor ident) ctor_decl;
                    print_field_raw ();
                    Format.fprintf formatter " =@ ";
                    print_field None;
                    pos + 1
                  | Sig_module (ident, { md_type; _ }, _) ->
                    print_ident "module" ident;
                    let ty : Cmt_file.core_or_module_type = Module md_type in
                    print_field (Some ty);
                    pos + 1
                  | Sig_class (ident, _, _) ->
                    print_ident "class" ident;
                    pos + 1  (* CR mshinwell: should print these *)
                  | Sig_type (ident, type_decl, _) ->
                    Format.fprintf formatter
                      "@[<hov 2>@{<type_colour>%a@}"
                      (Printtyp.type_declaration ident) type_decl;
                    pos
                  | Sig_modtype (ident, mod_type_decl) ->
                    Format.fprintf formatter
                      "@[<hov 2>@{<type_colour>%a@}"
                      (Printtyp.modtype_declaration ident) mod_type_decl;
                    pos
                  | Sig_class_type (ident, class_type_decl, _) ->
                    Format.fprintf formatter
                      "@[<hov 2>@{<type_colour>%a@}"
                      (Printtyp.cltype_declaration ident) class_type_decl;
                    pos
                in
                Format.fprintf formatter "@]";
                Some next_pos, false
              end
          in
          print_sig_items ~pos ~first ~in_type_group env sig_items
      in
      Printtyp.wrap_env (fun env -> env) (fun sg ->
          print_sig_items ~pos:(Some 0) ~first:true ~in_type_group:false
            env sg)
        sg;
      Format.fprintf formatter "@]@ end";
      if state.depth = 0 && actual_module_block_size > 1 then begin
        Format.fprintf formatter "@]"
      end

  let print_short_value t ~state ~type_of_ident:type_and_env v : unit =
    let formatter = state.formatter in
    match
      Our_type_oracle.find_type_information t.type_oracle ~formatter
        type_and_env ~scrutinee:v
    with
    (* CR mshinwell: should say "immediate" not "unboxed" *)
    | Obj_immediate -> Format.fprintf formatter "unboxed"
    | Obj_immediate_but_should_be_boxed ->
      if V.int v = Some 0 then Format.fprintf formatter "unboxed/uninited"
      else Format.fprintf formatter "unboxed (?)"
    | Obj_boxed_traversable -> Format.fprintf formatter "boxed"
    | Obj_boxed_not_traversable -> Format.fprintf formatter "boxed-not-trav."
    | Int ->
      begin match V.int v with
      | Some i -> Format.fprintf formatter "%d" i
      | None -> Format.fprintf formatter "unavailable"
      end
    | Char -> print_char t ~state v
    | Unit -> Format.fprintf formatter "()"
    | Abstract _ -> Format.fprintf formatter "abstract"
    | Array _ -> Format.fprintf formatter "[| ... |]"
    | List _ when not (V.is_block v) && not (V.is_null v) ->
      Format.fprintf formatter "[]"
    | List _ -> Format.fprintf formatter "[...]"
    | Ref _ -> Format.fprintf formatter "ref ..."
    | Tuple _ -> Format.fprintf formatter "(...)"
    | Constant_constructor _ -> Format.fprintf formatter "variant"
    | Non_constant_constructor _ -> Format.fprintf formatter "variant"
    | Record _ -> Format.fprintf formatter "{ ... }"
    | Open -> Format.fprintf formatter "open"
    | String ->
      print_string t ~state:{ state with max_string_length = 10; } v
    | Float -> print_float t ~state v
    | Float_array -> Format.fprintf formatter "[| ... |]"
    | Closure -> Format.fprintf formatter "function"
    | Lazy -> Format.fprintf formatter "lazy"
    | Object -> Format.fprintf formatter "object"
    | Abstract_tag -> Format.fprintf formatter "abstract-tag"
    | Format6 -> Format.fprintf formatter "format6"
    | Stdlib_set _ -> Format.fprintf formatter "Stdlib.Set"
    | Stdlib_map _ -> Format.fprintf formatter "Stdlib.Map"
    | Stdlib_hashtbl _ -> Format.fprintf formatter "Stdlib.Hashtbl"
    | Custom -> Format.fprintf formatter "custom"
    | Module _ -> Format.fprintf formatter "<module block>"
    | Unknown -> Format.fprintf formatter "unknown"

  let print_short_type t ~state ~type_of_ident:type_and_env v : unit =
    let formatter = state.formatter in
    match
      Our_type_oracle.find_type_information t.type_oracle ~formatter
        type_and_env ~scrutinee:v
    with
    | Obj_immediate -> Format.fprintf formatter "unboxed"
    | Obj_immediate_but_should_be_boxed ->
      if V.int v = Some 0 then Format.fprintf formatter "unboxed/uninited"
      else Format.fprintf formatter "unboxed (?)"
    | Obj_boxed_traversable -> Format.fprintf formatter "boxed"
    | Obj_boxed_not_traversable -> Format.fprintf formatter "boxed-not-trav."
    | Int ->
      begin match V.int v with
      | Some _ -> Format.fprintf formatter "int"
      | None -> Format.fprintf formatter "int (?)"
      end
    | Char -> Format.fprintf formatter "char"
    | Unit -> Format.fprintf formatter "unit"
    | Abstract _ -> Format.fprintf formatter "abstract"
    | Array _ -> Format.fprintf formatter "array"
    | List _ -> Format.fprintf formatter "list"
    | Ref _ -> Format.fprintf formatter "ref"
    | Tuple _ -> Format.fprintf formatter "tuple"
    | Constant_constructor _ -> Format.fprintf formatter "variant"
    | Non_constant_constructor _ -> Format.fprintf formatter "variant"
    | Record _ -> Format.fprintf formatter "record"
    | Open -> Format.fprintf formatter "open"
    | String -> Format.fprintf formatter "string"
    | Float -> Format.fprintf formatter "float"
    | Float_array -> Format.fprintf formatter "float array"
    | Closure -> Format.fprintf formatter "function"
    | Lazy -> Format.fprintf formatter "lazy"
    | Object -> Format.fprintf formatter "object"
    | Abstract_tag -> Format.fprintf formatter "abstract-tag"
    | Format6 -> Format.fprintf formatter "format6"
    | Stdlib_set _ -> Format.fprintf formatter "Stdlib.Set"
    | Stdlib_map _ -> Format.fprintf formatter "Stdlib.Map"
    | Stdlib_hashtbl _ -> Format.fprintf formatter "Stdlib.Hashtbl"
    | Custom -> Format.fprintf formatter "custom"
    | Module _ -> Format.fprintf formatter "<module>"
    | Unknown -> Format.fprintf formatter "unknown"

  (* CR mshinwell: remove search path param *)
  let print t frame ~scrutinee ~dwarf_type ~summary ~max_depth
        ~max_string_length
        ~cmt_file_search_path:_ ~formatter ~only_print_short_type
        ~only_print_short_value =
    Clflags.real_paths := false;  (* Enable short-paths. *)
    D.with_formatter_margins formatter ~summary (fun formatter ->
      if debug then begin
        Format.printf "Value_printer.print %a type %s\n%!"
          V.print scrutinee dwarf_type
      end;
      let type_of_ident =
        match
          Cmt_cache.find_cached_type t.cmt_cache ~cached_type:dwarf_type
        with
        | Some type_and_env -> Some type_and_env
        | None ->
          Type_helper.type_and_env_from_dwarf_type ~dwarf_type
            ~cmt_cache:t.cmt_cache frame
      in
      let is_unit =
        (* Print variables (in particular parameters) of type [unit] even when
           unavailable. *)
        match type_of_ident with
        | None | Some (Module _, _, _) -> false
        | Some (Core ty, _env, _) ->
          match ty.desc with
          | Tconstr (path, _, _) -> Path.same path Predef.path_unit
          | _ -> false
      in
      (* Example of this null case: [Iphantom_read_var_field] on something
         unavailable. *)
      if V.is_null scrutinee
        && (not only_print_short_type)
        && (not is_unit)
      then begin
        (* CR mshinwell: This should still return a type even when not in
           short-type mode, no? *)
        Format.fprintf formatter "%s" optimized_out;
        Format.pp_print_flush formatter ()
      end else begin
        if debug then Printf.printf "Value_printer.print entry point\n%!";
        let state = {
          summary;
          depth = 0;
          max_depth;
          max_string_length;
          print_sig = true;
          formatter;
          (* CR mshinwell: pass this next one as an arg to this function *)
          max_array_elements_etc_to_print = 10;
          only_print_short_type;
          only_print_short_value;
          operator_above = Nothing;
          visited = V.Set.empty;
        }
        in
        let env =
          match type_of_ident with
          | None -> Env.empty
          | Some (_, env, _) -> env
        in
        Printtyp.wrap_printing_env ~error:false env (fun () ->
          if only_print_short_type then begin
            let type_of_ident =
              match type_of_ident with
              | None -> None
              | Some (ty, env, _) -> Some (ty, env)
            in
            print_short_type t ~state ~type_of_ident scrutinee
          end else if only_print_short_value then begin
            let type_of_ident =
              match type_of_ident with
              | None -> None
              | Some (ty, env, _) -> Some (ty, env)
            in
            print_short_value t ~state ~type_of_ident scrutinee
          end else begin
            Format.fprintf formatter "@[<hov 2>";
            print_value t ~state ~type_of_ident scrutinee;
            Format.fprintf formatter "@]"
          end);
        Format.pp_print_flush formatter ()
      end)
end
