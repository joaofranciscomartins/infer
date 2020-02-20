(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

type violation = {nullsafe_mode: NullsafeMode.t; lhs: Nullability.t; rhs: Nullability.t}
[@@deriving compare]

type assignment_type =
  | PassingParamToFunction of function_info
  | AssigningToField of Fieldname.t
  | ReturningFromFunction of Procname.t
[@@deriving compare]

and function_info =
  { param_signature: AnnotatedSignature.param_signature
  ; model_source: AnnotatedSignature.model_source option
  ; actual_param_expression: string
  ; param_position: int
  ; function_procname: Procname.t }

let check ~(nullsafe_mode : NullsafeMode.t) ~lhs ~rhs =
  let falls_under_optimistic_third_party =
    match nullsafe_mode with
    | NullsafeMode.Default when Config.nullsafe_optimistic_third_party_params_in_non_strict -> (
      match lhs with Nullability.ThirdPartyNonnull -> true | _ -> false )
    | _ ->
        false
  in
  let is_allowed_assignment =
    Nullability.is_subtype ~supertype:lhs ~subtype:rhs
    || falls_under_optimistic_third_party
    (* For better adoption we allow certain conversions. Otherwise using code checked under
       different nullsafe modes becomes a pain because of extra warnings. *)
    (* TODO(T62521386): consider using caller context when determining nullability to get rid of
       white-lists. *)
    || Nullability.is_considered_nonnull ~nullsafe_mode rhs
  in
  Result.ok_if_true is_allowed_assignment ~error:{nullsafe_mode; lhs; rhs}


let get_origin_opt assignment_type origin =
  let should_show_origin =
    match assignment_type with
    | PassingParamToFunction {actual_param_expression} ->
        not
          (ErrorRenderingUtils.is_object_nullability_self_explanatory
             ~object_expression:actual_param_expression origin)
    | AssigningToField _ | ReturningFromFunction _ ->
        true
  in
  if should_show_origin then Some origin else None


let pp_param_name fmt mangled =
  let name = Mangled.to_string mangled in
  if String.is_substring name ~substring:"_arg_" then
    (* The real name was not fetched for whatever reason, this is an autogenerated name *)
    Format.fprintf fmt ""
  else Format.fprintf fmt "(%a)" MarkupFormatter.pp_monospaced name


let mk_description_for_bad_param_passed
    {model_source; param_signature; actual_param_expression; param_position; function_procname}
    ~param_nullability nullability_evidence =
  let nullability_evidence_as_suffix =
    Option.value_map nullability_evidence ~f:(fun evidence -> ": " ^ evidence) ~default:""
  in
  let module MF = MarkupFormatter in
  let argument_description =
    if String.equal actual_param_expression "null" then "is `null`"
    else
      let nullability_descr =
        match param_nullability with
        | Nullability.Null ->
            "`null`"
        | Nullability.Nullable ->
            "nullable"
        | other ->
            Logging.die InternalError
              "mk_description_for_bad_param:: invariant violation: unexpected nullability %a"
              Nullability.pp other
      in
      Format.asprintf "%a is %s" MF.pp_monospaced actual_param_expression nullability_descr
  in
  let suggested_file_to_add_third_party =
    match model_source with
    | None ->
        ThirdPartyAnnotationInfo.lookup_related_sig_file_for_proc
          (ThirdPartyAnnotationGlobalRepo.get_repo ())
          function_procname
    | Some _ ->
        (* This is a different case:
           suggestion to add third party is irrelevant (it is already added or modelled internally).
        *)
        None
  in
  match suggested_file_to_add_third_party with
  | Some sig_file_name ->
      (* This is a special case. While for FB codebase we can assume "not annotated hence not nullable" rule for all_whitelisted signatures,
         This is not the case for third party functions, which can have different conventions,
         So we can not just say "param is declared as non-nullable" like we say for FB-internal or modelled case:
         param can be nullable according to API but it was just not annotated.
         So we phrase it differently to remain truthful, but as specific as possible.
      *)
      let procname_str = Procname.to_simplified_string ~withclass:true function_procname in
      Format.asprintf
        "Third-party %a is missing a signature that would allow passing a nullable to param #%d%a. \
         Actual argument %s%s. Consider adding the correct signature of %a to %s."
        MF.pp_monospaced procname_str param_position pp_param_name param_signature.mangled
        argument_description nullability_evidence_as_suffix MF.pp_monospaced procname_str
        (ThirdPartyAnnotationGlobalRepo.get_user_friendly_third_party_sig_file_name
           ~filename:sig_file_name)
  | None ->
      let nonnull_evidence =
        match model_source with
        | None ->
            ""
        | Some InternalModel ->
            " (according to nullsafe internal models)"
        | Some (ThirdPartyRepo {filename; line_number}) ->
            Format.sprintf " (see %s at line %d)"
              (ThirdPartyAnnotationGlobalRepo.get_user_friendly_third_party_sig_file_name ~filename)
              line_number
      in
      Format.asprintf "%a: parameter #%d%a is declared non-nullable%s but the argument %s%s."
        MF.pp_monospaced
        (Procname.to_simplified_string ~withclass:true function_procname)
        param_position pp_param_name param_signature.mangled nonnull_evidence argument_description
        nullability_evidence_as_suffix


let get_issue_type = function
  | PassingParamToFunction _ ->
      IssueType.eradicate_parameter_not_nullable
  | AssigningToField _ ->
      IssueType.eradicate_field_not_nullable
  | ReturningFromFunction _ ->
      IssueType.eradicate_return_not_nullable


let violation_description {nullsafe_mode; rhs} ~assignment_location assignment_type ~rhs_origin =
  let special_message =
    if not (NullsafeMode.equal NullsafeMode.Default nullsafe_mode) then
      ErrorRenderingUtils.mk_special_nullsafe_issue ~nullsafe_mode ~bad_nullability:rhs
        ~bad_usage_location:assignment_location rhs_origin
    else None
  in
  match special_message with
  | Some desc ->
      desc
  | _ ->
      let nullability_evidence =
        get_origin_opt assignment_type rhs_origin
        |> Option.bind ~f:(fun origin -> TypeOrigin.get_description origin)
      in
      let nullability_evidence_as_suffix =
        Option.value_map nullability_evidence ~f:(fun evidence -> ": " ^ evidence) ~default:""
      in
      let module MF = MarkupFormatter in
      let error_message =
        match assignment_type with
        | PassingParamToFunction function_info ->
            mk_description_for_bad_param_passed function_info nullability_evidence
              ~param_nullability:rhs
        | AssigningToField field_name ->
            let rhs_description =
              Nullability.(
                match rhs with
                | Null ->
                    "`null`"
                | Nullable ->
                    "a nullable"
                | other ->
                    Logging.die InternalError
                      "violation_description(assign_field):: invariant violation: unexpected \
                       nullability %a"
                      Nullability.pp other)
            in
            Format.asprintf "%a is declared non-nullable but is assigned %s%s." MF.pp_monospaced
              (Fieldname.get_field_name field_name)
              rhs_description nullability_evidence_as_suffix
        | ReturningFromFunction function_proc_name ->
            let return_description =
              Nullability.(
                match rhs with
                | Null ->
                    (* Return `null` in all_whitelisted branches *)
                    "`null`"
                | Nullable ->
                    "a nullable value"
                | other ->
                    Logging.die InternalError
                      "violation_description(ret_fun):: invariant violation: unexpected \
                       nullability %a"
                      Nullability.pp other)
            in
            Format.asprintf "%a: return type is declared non-nullable but the method returns %s%s."
              MF.pp_monospaced
              (Procname.to_simplified_string ~withclass:false function_proc_name)
              return_description nullability_evidence_as_suffix
      in
      let issue_type = get_issue_type assignment_type in
      (error_message, issue_type, assignment_location)


let violation_severity {nullsafe_mode} = NullsafeMode.severity nullsafe_mode
