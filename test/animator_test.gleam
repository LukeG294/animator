//// The test entry point: which tests belong to which question of the project.
////
//// `gleam test` runs every test in this directory with gleeunit, as usual;
//// `gleam test -- q1` runs one question's tests and `gleam test -- score`
//// reports every question's. grader.gleam is the whole of that machinery.
//// Problems 9 to 11 are scored on Gradescope, by tests that aren't distributed with
//// the project. The tests for q9 to q11 here only check that the app has the elements
//// that Gradescope's tests look for (test_ids_test.gleam), so they are worth no points
//// here. The checks in autograders.gleam are untimed_checks, since they can take far
//// longer than the grader's timeout. The test for q12 only checks that extension.txt
//// has been filled in, so it's worth no points.
////
//// A test is listed under the first question whose part of the interpreter it
//// needs, so a question's tests should all pass once that question is done
//// (assuming the earlier ones are).

import autograders
import evaluator_test as evaluator
import extension_test as extension
import grader.{check, question, untimed_check}
import test_ids_test as test_ids

pub fn main() -> Nil {
  grader.main([
    question("q1", 2, [
      check("unbound_variable_test", evaluator.unbound_variable_test),
      check("bound_variable_test", evaluator.bound_variable_test),
      check(
        "lookup_finds_nearest_binding_test",
        evaluator.lookup_finds_nearest_binding_test,
      ),
      check("lookup_unbound_name_test", evaluator.lookup_unbound_name_test),
    ]),
    question("q2", 2, [
      check("call_test", evaluator.call_test),
      check(
        "field_access_wrong_type_test",
        evaluator.field_access_wrong_type_test,
      ),
      check(
        "unsupported_list_function_test",
        evaluator.unsupported_list_function_test,
      ),
      check("builtin_step_limit_test", evaluator.builtin_step_limit_test),
      check(
        "call_evaluates_once_in_order_test",
        evaluator.call_evaluates_once_in_order_test,
      ),
      check(
        "call_reports_first_error_test",
        evaluator.call_reports_first_error_test,
      ),
      check("pipe_evaluates_once_test", evaluator.pipe_evaluates_once_test),
    ]),
    question("q3", 2, [
      check("list_literal_test", evaluator.list_literal_test),
      check("builtin_as_value_test", evaluator.builtin_as_value_test),
      check("list_prepend_test", evaluator.list_prepend_test),
      check(
        "list_and_field_evaluate_once_test",
        evaluator.list_and_field_evaluate_once_test,
      ),
      check("not_equal_test", evaluator.not_equal_test),
      check("list_length_test", evaluator.list_length_test),
    ]),
    question("q4", 2, [
      check("shape_slider_is_bound_test", evaluator.shape_slider_is_bound_test),
      check("field_access_test", evaluator.field_access_test),
      check("field_access_nested_test", evaluator.field_access_nested_test),
      check("call_non_function_test", evaluator.call_non_function_test),
      check("error_line_test", evaluator.error_line_test),
      check("let_evaluates_once_test", evaluator.let_evaluates_once_test),
      check(
        "let_keeps_earlier_bindings_test",
        evaluator.let_keeps_earlier_bindings_test,
      ),
      check("let_rebinding_test", evaluator.let_rebinding_test),
      check("let_scope_test", evaluator.let_scope_test),
    ]),
    question("q5", 2, [
      check("case_test", evaluator.case_test),
      check("case_on_comparison_test", evaluator.case_on_comparison_test),
      check(
        "case_evaluates_subject_once_test",
        evaluator.case_evaluates_subject_once_test,
      ),
      check(
        "case_evaluates_matching_arm_once_test",
        evaluator.case_evaluates_matching_arm_once_test,
      ),
      check("variable_pattern_test", evaluator.variable_pattern_test),
      check(
        "case_pattern_shadowing_test",
        evaluator.case_pattern_shadowing_test,
      ),
      check("case_int_pattern_test", evaluator.case_int_pattern_test),
      check("short_circuit_test", evaluator.short_circuit_test),
      check(
        "boolean_operator_type_errors_test",
        evaluator.boolean_operator_type_errors_test,
      ),
    ]),
    question("q6", 2, [
      check("list_pattern_test", evaluator.list_pattern_test),
      check("list_pattern_rest_test", evaluator.list_pattern_rest_test),
      check(
        "case_keeps_outer_bindings_test",
        evaluator.case_keeps_outer_bindings_test,
      ),
      check("case_scope_test", evaluator.case_scope_test),
    ]),
    question("q7", 2, [
      check("helper_recursion_test", evaluator.helper_recursion_test),
      check("error_line_in_helper_test", evaluator.error_line_in_helper_test),
      check(
        "named_function_as_value_test",
        evaluator.named_function_as_value_test,
      ),
      check(
        "non_tail_recursion_limit_test",
        evaluator.non_tail_recursion_limit_test,
      ),
      check(
        "runaway_append_step_limit_test",
        evaluator.runaway_append_step_limit_test,
      ),
      check(
        "runaway_flatten_step_limit_test",
        evaluator.runaway_flatten_step_limit_test,
      ),
      check(
        "branching_recursion_step_limit_test",
        evaluator.branching_recursion_step_limit_test,
      ),
      check(
        "deep_equality_recursion_limit_test",
        evaluator.deep_equality_recursion_limit_test,
      ),
      check(
        "user_function_evaluates_once_test",
        evaluator.user_function_evaluates_once_test,
      ),
      check(
        "parameters_bind_in_order_test",
        evaluator.parameters_bind_in_order_test,
      ),
      check(
        "each_call_has_its_own_frame_test",
        evaluator.each_call_has_its_own_frame_test,
      ),
      check(
        "call_keeps_caller_bindings_test",
        evaluator.call_keeps_caller_bindings_test,
      ),
      check(
        "function_cannot_see_caller_test",
        evaluator.function_cannot_see_caller_test,
      ),
      check(
        "function_names_do_not_outlive_call_test",
        evaluator.function_names_do_not_outlive_call_test,
      ),
      check(
        "parameter_hides_global_test",
        evaluator.parameter_hides_global_test,
      ),
      check("mutual_recursion_test", evaluator.mutual_recursion_test),
    ]),
    question("q8", 2, [
      check("lambda_map_test", evaluator.lambda_map_test),
      check(
        "closure_captures_locals_test",
        evaluator.closure_captures_locals_test,
      ),
      check(
        "closure_captures_slider_test",
        evaluator.closure_captures_slider_test,
      ),
      check("function_in_let_test", evaluator.function_in_let_test),
      check("function_capture_test", evaluator.function_capture_test),
      check("curried_call_test", evaluator.curried_call_test),
      check(
        "discarded_lambda_param_test",
        evaluator.discarded_lambda_param_test,
      ),
      check("list_builtins_test", evaluator.list_builtins_test),
      check(
        "list_builtin_type_errors_test",
        evaluator.list_builtin_type_errors_test,
      ),
      check(
        "error_inside_list_function_test",
        evaluator.error_inside_list_function_test,
      ),
      check("error_line_in_lambda_test", evaluator.error_line_in_lambda_test),
      check("error_message_line_test", evaluator.error_message_line_test),
      check(
        "lambda_body_evaluates_per_call_test",
        evaluator.lambda_body_evaluates_per_call_test,
      ),
      check(
        "list_builtins_apply_once_per_element_test",
        evaluator.list_builtins_apply_once_per_element_test,
      ),
      check(
        "sugar_evaluates_per_call_test",
        evaluator.sugar_evaluates_per_call_test,
      ),
      check(
        "closure_uses_defining_frame_test",
        evaluator.closure_uses_defining_frame_test,
      ),
      check(
        "closure_cannot_see_caller_test",
        evaluator.closure_cannot_see_caller_test,
      ),
      check(
        "closure_sees_only_earlier_bindings_test",
        evaluator.closure_sees_only_earlier_bindings_test,
      ),
      check(
        "closures_are_independent_test",
        evaluator.closures_are_independent_test,
      ),
      check(
        "closure_sees_every_enclosing_frame_test",
        evaluator.closure_sees_every_enclosing_frame_test,
      ),
      check("lambda_shadowing_test", evaluator.lambda_shadowing_test),
      check(
        "lambda_recursion_has_own_frames_test",
        evaluator.lambda_recursion_has_own_frames_test,
      ),
      check(
        "lambda_names_do_not_outlive_call_test",
        evaluator.lambda_names_do_not_outlive_call_test,
      ),
      check("use_scope_test", evaluator.use_scope_test),
      check("capture_scope_test", evaluator.capture_scope_test),
      check("lambda_name_in_errors_test", evaluator.lambda_name_in_errors_test),
      check("list_as_a_local_name_test", evaluator.list_as_a_local_name_test),
    ]),
    question("q9", 0, [
      check("canvas_id_test", test_ids.canvas_id_test),
      check("code_editor_id_test", test_ids.code_editor_id_test),
    ]),
    question("q10", 0, [
      check("shape_slider_id_test", test_ids.shape_slider_id_test),
      check("speed_slider_id_test", test_ids.speed_slider_id_test),
    ]),
    question("q11", 0, [
      check("drawing_select_id_test", test_ids.drawing_select_id_test),
    ]),
    question("q12", 0, [
      check("extension_description_test", extension.description_test),
    ]),
    question("q13", 1, [
      untimed_check(
        "deployment_autograder_test",
        autograders.deployment_autograder_test,
      ),
    ]),
    question("q14", 1, [
      untimed_check("video_autograder_test", autograders.video_autograder_test),
    ]),
  ])
}
