"""The gate is the only thing standing between an agent and a wrong answer.

So it gets tested like anything else. These do not need the agent or the Mojo
compiler — they check the comparison logic, which is where a false accept would
come from.
"""

from __future__ import annotations

import importlib.util
import os
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "convert", os.path.join(ROOT, "bin", "convert.py"))
convert = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(convert)

np = pytest.importorskip("numpy")


def test_a_wrong_return_value_is_rejected():
    params = [("xs", "list[float]")]

    def truth(xs):
        return float(sum(xs))

    def wrong(*cargs):
        return 0.0

    with pytest.raises(RuntimeError, match="disagrees"):
        convert.verify(truth, wrong, params, "float")


def test_an_unwritten_buffer_is_rejected():
    """A kernel that returns the right number and leaves the caller's array
    untouched is the failure mode that a return-value check cannot see."""
    params = [("xs", "list[float]"), ("k", "float")]

    def truth(xs, k):
        for i in range(len(xs)):
            xs[i] = xs[i] * k
        return float(xs.sum())

    def right_number_no_write(addr, length, k):
        # Computes the correct total without storing anything.
        buf = (np.ctypeslib.as_array(
            (np.ctypeslib.ctypes.c_double * length).from_address(addr)))
        return float((buf * k).sum())

    with pytest.raises(RuntimeError, match="buffer"):
        convert.verify(truth, right_number_no_write, params, "float")


def test_agreement_within_reassociation_tolerance_is_accepted():
    params = [("xs", "list[float]")]

    def truth(xs):
        return float(sum(xs))

    def nudged(addr, length):
        buf = np.ctypeslib.as_array(
            (np.ctypeslib.ctypes.c_double * length).from_address(addr))
        # A rounding-scale difference, which reassociating a sum really does
        # produce and which must not be called a wrong answer.
        return float(buf.sum()) * (1 + 1e-12)

    convert.verify(truth, nudged, params, "float")


def test_a_function_without_annotations_is_skipped_not_guessed():
    import ast

    fn = ast.parse("def f(xs):\n    return 1.0\n").body[0]
    with pytest.raises(convert.Skip, match="no annotation"):
        convert.signature_of(fn)


def test_the_declared_abi_matches_the_ctypes_binding():
    """The prompt tells the agent one signature and the harness binds another if
    these two ever drift, and then every conversion fails for the wrong reason."""
    params = [("m", "list[list[float]]"), ("xs", "list[float]"), ("k", "int")]
    spec = convert.abi_spec("f", params, "float")
    argtypes, restype = convert.ctypes_signature(params, "float")
    # matrix: addr+len+cols, vector: addr+len, scalar: one
    assert len(argtypes) == 3 + 2 + 1
    assert spec.count(":") == len(argtypes) + 1   # params, plus the def's own
    assert "m_cols: Int" in spec and "xs_len: Int" in spec and "k: Int" in spec
    assert restype is not None
