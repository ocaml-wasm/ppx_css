open! Core
open! Ppxlib
open Css_jane

type t =
  { original_declaration_string : string loc
  ; parsed_parts : Ppx_string.Parse_result.t
  ; inferred_do_not_hash : string list
  ; anonymous_variables : Anonymous_variable.Collection.t
  ; substituted_declarations : string
  ; anonymous_class_name : string
  }
[@@deriving fields ~getters]

let inferred_do_not_hash ~string_loc ~parsed_parts =
  let placeholder_class = "ppx_css_internal_only_class" in
  let placeholder_variable = "--ppx_css_internal_only_variable" in
  let anonymous_declarations =
    let { Ppx_string.Parse_result.parts; locations_are_precise = _ } = parsed_parts in
    List.map parts ~f:(function
      | Literal { loc = _; txt } -> txt
      | Interpreted _ -> [%string "var(%{placeholder_variable})"])
    |> String.concat ~sep:""
  in
  let style_sheet =
    [%string {|
.%{placeholder_class}  {
%{anonymous_declarations}
}
  |}]
    |> Stylesheet.of_string ~pos:string_loc.loc_start
  in
  let ( - ) = Set.remove in
  Traverse_css.Get_all_identifiers.css_variables style_sheet
  - placeholder_class
  - placeholder_variable
  |> Set.to_list
;;

module Find_anonymous_variables = struct
  type result =
    { anonymous_variables : Anonymous_variable.t list
    ; substituted_declarations : string
    }

  let f ~(parsed_parts : Ppx_string.Parse_result.t) : result =
    let%tydi { parts; locations_are_precise = _ } = parsed_parts in
    let buffer = Buffer.create 64 in
    let anonymous_variables =
      List.fold
        parts
        ~init:Reversed_list.[]
        ~f:(fun (acc : Anonymous_variable.t Reversed_list.t) -> function
          | Literal { txt = literal; loc = _ } ->
            Buffer.add_string buffer literal;
            acc
          | Interpreted
              { loc_start = _
              ; value
              ; module_path
              ; pad_length = _
              ; loc_end = _
              ; interpreted_string = _
              } ->
            let expression =
              match module_path with
              | None -> value
              | Some { txt = lident; loc } ->
                let open (val Ast_builder.make loc) in
                let to_string_css =
                  pexp_ident
                    (let lident = Ldot (lident, "to_string_css") in
                     { txt = lident; loc })
                in
                [%expr [%e to_string_css] [%e value]]
            in
            let anonymous_variable = Anonymous_variable.of_expression expression in
            let acc = Reversed_list.(anonymous_variable :: acc) in
            let name = Anonymous_variable.name anonymous_variable in
            Buffer.add_string buffer (Anonymous_variable.Name.to_css_variable name);
            acc)
    in
    let substituted_declarations = Buffer.contents buffer in
    let anonymous_variables = Reversed_list.rev anonymous_variables in
    { anonymous_variables; substituted_declarations }
  ;;
end

let anonymous_class_name = "ppx_css_anonymous_class"

let create ~string_loc original_declaration_string =
  let parsed_parts =
    Ppx_string.parse_parts ~string_loc ~delimiter:None original_declaration_string
  in
  let inferred_do_not_hash = inferred_do_not_hash ~string_loc ~parsed_parts in
  let%tydi { anonymous_variables; substituted_declarations } =
    Find_anonymous_variables.f ~parsed_parts
  in
  let anonymous_variables = Anonymous_variable.Collection.of_list anonymous_variables in
  { original_declaration_string = { txt = original_declaration_string; loc = string_loc }
  ; parsed_parts
  ; inferred_do_not_hash
  ; anonymous_variables
  ; substituted_declarations
  ; anonymous_class_name
  }
;;

let always_hash t =
  let init = String.Set.singleton anonymous_class_name in
  List.fold t.anonymous_variables.variables ~init ~f:(fun acc variable ->
    let name = Anonymous_variable.name variable in
    Set.add acc ("--" ^ Anonymous_variable.Name.to_string name))
;;

let%expect_test "[always_hash]" =
  let test s =
    let result = create ~string_loc:Location.none s in
    print_s [%sexp (always_hash result : String.Set.t)]
  in
  test {|background-color: red|};
  [%expect {| (ppx_css_anonymous_class) |}];
  (* (--red) is not hashed *)
  test {|background-color: var(--red)|};
  [%expect {| (ppx_css_anonymous_class) |}];
  test {|background-color: %{color}|};
  [%expect {| (--ppx_css_anonymous_var_1 ppx_css_anonymous_class) |}]
;;

let%expect_test "[inferred_do_not_hash]" =
  let test s =
    let result = create ~string_loc:Location.none s in
    print_s [%sexp (result.inferred_do_not_hash : string list)]
  in
  test {|background-color: red|};
  [%expect {| () |}];
  test {|background-color: %{color};|};
  [%expect {| () |}];
  test {|background-color: %{color#Module.Foo};|};
  [%expect {| () |}];
  test {|
    background-color: red;
    background-color: var(--foo);
  |};
  [%expect {| (--foo) |}];
  (* No trailing semi-colon on last declaration. *)
  test
    {|
    background-color: red;
    background-color: var(--foo);
    background-color: var(--beep)
  |};
  [%expect {| (--beep --foo) |}];
  test {|
    background-color: var(--i-have-slashes);
  |};
  [%expect {| (--i-have-slashes) |}];
  test {|
    --tom: tomato;
    background-color: var(--tom);
  |};
  [%expect {| (--tom) |}]
;;

let to_stylesheet_string t =
  [%string {|
.%{anonymous_class_name} { %{t.substituted_declarations} }|}]
;;

let%expect_test _ =
  let test s =
    Anonymous_variable.For_testing.restart_identifiers ();
    create ~string_loc:Location.none s |> to_stylesheet_string |> print_endline
  in
  test {|background-color: blue|};
  [%expect {|
    .ppx_css_anonymous_class { background-color: blue } |}];
  test {|background-color: %{color};|};
  [%expect
    {|
    .ppx_css_anonymous_class { background-color: var(--ppx_css_anonymous_var_1); } |}];
  test {|background-color: %{color#Module.Foo};|};
  [%expect
    {|
    .ppx_css_anonymous_class { background-color: var(--ppx_css_anonymous_var_1); } |}];
  test
    {|
    background-color: red;
    background-color: var(--foo);
    --tom: tomato;
    --tom: %{color};
    background-color: %{f () () ()};
    background-color: %{g ()#Mod.Mod};

  |};
  [%expect
    {|
    .ppx_css_anonymous_class {
        background-color: red;
        background-color: var(--foo);
        --tom: tomato;
        --tom: var(--ppx_css_anonymous_var_1);
        background-color: var(--ppx_css_anonymous_var_2);
        background-color: var(--ppx_css_anonymous_var_3);

       } |}]
;;

let inferred_do_not_hash t = t.inferred_do_not_hash

module For_stylesheet = struct
  type t =
    { original_stylesheet_string : string loc
    ; substituted_stylesheet : string
    ; anonymous_variables : Anonymous_variable.Collection.t
    }

  let create ~string_loc stylesheet_string =
    let original_stylesheet_string = { txt = stylesheet_string; loc = string_loc } in
    let parsed_parts =
      Ppx_string.parse_parts ~string_loc ~delimiter:None stylesheet_string
    in
    let%tydi { anonymous_variables; substituted_declarations } =
      Find_anonymous_variables.f ~parsed_parts
    in
    let anonymous_variables = Anonymous_variable.Collection.of_list anonymous_variables in
    { original_stylesheet_string
    ; anonymous_variables
    ; substituted_stylesheet = substituted_declarations
    }
  ;;

  let anonymous_variables t = t.anonymous_variables
  let to_stylesheet_string t = t.substituted_stylesheet

  let always_hash t =
    List.fold
      t.anonymous_variables.variables
      ~init:String.Set.empty
      ~f:(fun acc variable ->
      let name = Anonymous_variable.name variable in
      Set.add acc ("--" ^ Anonymous_variable.Name.to_string name))
  ;;
end
