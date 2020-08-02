# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import datetime
import logging
import os
from collections import defaultdict
from typing import Any, Dict, List, Optional, Set, Tuple

import ujson as json

from .models import (
    DBID,
    SHARED_TEXT_LENGTH,
    Issue,
    IssueDBID,
    IssueInstance,
    IssueInstanceFixInfo,
    IssueStatus,
    Run,
    RunStatus,
    SharedText,
    SharedTextKind,
    SourceLocation,
    TraceFrame,
    TraceFrameAnnotation,
    TraceKind,
    create as create_models,
)
from .pipeline import DictEntries, PipelineStep, Summary
from .trace_graph import TraceGraph


log = logging.getLogger("sapp")


# pyre-fixme[13]: Attribute `graph` is never initialized.
# pyre-fixme[13]: Attribute `summary` is never initialized.
class ModelGenerator(PipelineStep[DictEntries, TraceGraph]):
    def __init__(self) -> None:
        super().__init__()
        self.summary: Summary
        self.graph: TraceGraph
        self.visited_frames: Dict[int, Set[int]] = {}  # frame id -> leaf ids

    def run(self, input: DictEntries, summary: Summary) -> Tuple[TraceGraph, Summary]:
        self.summary = summary

        self.summary["trace_entries"] = defaultdict(
            lambda: defaultdict(list)
        )  # : Dict[TraceKind, Dict[Tuple[str, str], Any]]
        self.summary["missing_traces"] = defaultdict(
            set
        )  # Dict[TraceKind, Set[Tuple[str, str]]]
        self.summary["big_tito"] = set()  # Set[Tuple[str, str, int]]

        self.graph = TraceGraph()
        self.summary["run"] = self._create_empty_run(status=RunStatus.INCOMPLETE)
        self.summary["run"].id = DBID()

        self.summary["trace_entries"][TraceKind.precondition] = input["preconditions"]
        self.summary["trace_entries"][TraceKind.postcondition] = input["postconditions"]
        callables = self._compute_callables_count(input)

        log.info("Generating issues and traces")
        for entry in input["issues"]:
            self._generate_issue(self.summary["run"], entry, callables)

        if self.summary.get("store_unused_models"):
            for trace_kind, traces in self.summary["trace_entries"].items():
                for _key, entry in traces:
                    self._generate_trace_frame(trace_kind, self.summary["run"], entry)

        return self.graph, self.summary

    def _compute_callables_count(self, iters: Dict[str, Any]):
        """Iterate over all issues and count the number of times each callable
        is seen."""
        count = dict.fromkeys([issue["callable"] for issue in iters["issues"]], 0)
        for issue in iters["issues"]:
            # pyre-fixme[6]: Expected `typing_extensions.Literal[0]` for 2nd param
            #  but got `int`.
            count[issue["callable"]] += 1

        return count

    def _create_empty_run(
        self, status=RunStatus.FINISHED, status_description=None
    ) -> Run:
        """setting boilerplate when creating a Run object"""
        # pyre-fixme[28]: Unexpected keyword argument `job_id`.
        run = Run(
            job_id=self.summary["job_id"],
            issue_instances=[],
            date=datetime.datetime.now(),
            status=status,
            status_description=status_description,
            repository=self.summary["repository"],
            branch=self.summary["branch"],
            commit_hash=self.summary["commit_hash"],
            kind=self.summary["run_kind"],
        )
        return run

    def _get_minimum_trace_length(self, entries: List[Dict]) -> int:
        length = None
        for entry in entries:
            for (_leaf, depth) in entry["leaves"]:
                if length is None or length > depth:
                    length = depth
        if length is not None:
            return length
        return 0

    def _generate_issue(self, run, entry, callablesCount):
        """Insert the issue instance into a run. This includes creating (for
        new issues) or finding (for existing issues) Issue objects to associate
        with the instances.
        Also create sink entries and associate related issues"""

        trace_frames = []

        for p in entry["preconditions"]:
            tf = self._generate_issue_traces(TraceKind.PRECONDITION, run, entry, p)
            trace_frames.append(tf)

        for p in entry["postconditions"]:
            tf = self._generate_issue_traces(TraceKind.POSTCONDITION, run, entry, p)
            trace_frames.append(tf)

        features = set()
        for f in entry["features"]:
            features.update(self._generate_issue_feature_contents(entry, f))

        callable = entry["callable"]
        handle = self._get_issue_handle(entry)
        initial_sources = {
            self._get_shared_text(SharedTextKind.SOURCE, kind)
            for (_name, kind, _depth) in entry["initial_sources"]
        }
        final_sinks = {
            self._get_shared_text(SharedTextKind.SINK, kind)
            for (_name, kind, _depth) in entry["final_sinks"]
        }

        source_details = {
            self._get_shared_text(SharedTextKind.SOURCE_DETAIL, name)
            for (name, _kind, _depth) in entry["initial_sources"]
            if name
        }
        sink_details = {
            self._get_shared_text(SharedTextKind.SINK_DETAIL, name)
            for (name, _kind, _depth) in entry["final_sinks"]
            if name
        }

        issue = Issue.Record(
            id=IssueDBID(),
            code=entry["code"],
            handle=handle,
            status=IssueStatus.UNCATEGORIZED,
            first_seen=run.date,
            run_id=run.id,
        )

        self.graph.add_issue(issue)

        fix_info = None
        fix_info_id = None
        if entry.get("fix_info") is not None:
            fix_info = IssueInstanceFixInfo.Record(
                id=DBID(), fix_info=json.dumps(entry["fix_info"])
            )
            fix_info_id = fix_info.id

        message = self._get_shared_text(SharedTextKind.MESSAGE, entry["message"])
        filename_record = self._get_shared_text(
            SharedTextKind.FILENAME, entry["filename"]
        )
        callable_record = self._get_shared_text(SharedTextKind.CALLABLE, callable)

        instance = IssueInstance.Record(
            id=DBID(),
            issue_id=issue.id,
            location=self.get_location(entry),
            filename_id=filename_record.id,
            callable_id=callable_record.id,
            run_id=run.id,
            fix_info_id=fix_info_id,
            message_id=message.id,
            rank=0,
            min_trace_length_to_sources=self._get_minimum_trace_length(
                entry["postconditions"]
            ),
            min_trace_length_to_sinks=self._get_minimum_trace_length(
                entry["preconditions"]
            ),
            callable_count=callablesCount[callable],
        )

        for sink in final_sinks:
            self.graph.add_issue_instance_shared_text_assoc(instance, sink)
        for detail in sink_details:
            self.graph.add_issue_instance_shared_text_assoc(instance, detail)
        for source in initial_sources:
            self.graph.add_issue_instance_shared_text_assoc(instance, source)
        for detail in source_details:
            self.graph.add_issue_instance_shared_text_assoc(instance, detail)

        if fix_info is not None:
            self.graph.add_issue_instance_fix_info(instance, fix_info)

        for trace_frame in trace_frames:
            self.graph.add_issue_instance_trace_frame_assoc(instance, trace_frame)

        for feature in features:
            feature = self._get_shared_text(SharedTextKind.FEATURE, feature)
            self.graph.add_issue_instance_shared_text_assoc(instance, feature)

        self.graph.add_issue_instance(instance)

    # We need to thread filename explicitly since the entry might be a callinfo.
    def _generate_tito(self, filename: str, entry, callable):
        titos = [
            SourceLocation(t["line"], t["start"], t["end"])
            for t in entry.get("titos", [])
        ]
        if len(titos) > 200:
            pre_key: Tuple[str, str, int] = (filename, callable, len(titos))
            if pre_key not in self.summary["big_tito"]:
                log.info("Big Tito: %s", str(pre_key))
                self.summary["big_tito"].add(pre_key)
            titos = titos[:200]
        return titos

    def _generate_issue_traces(self, kind: TraceKind, run, issue, callinfo):
        # Generates a synthetic trace frame from a forward or backward trace in callinfo
        # that represents a call edge from the issue callable to the start of a
        # a trace.
        # Generate all dependencies of this frame as well.
        caller = issue["callable"]
        callee = callinfo["callee"]
        callee_port = callinfo["port"]
        titos = self._generate_tito(issue["filename"], callinfo, caller)
        call_tf, leaf_ids = self._generate_raw_trace_frame(
            kind,
            run=run,
            filename=issue["filename"],
            caller=caller,
            caller_port="root",
            callee=callee,
            callee_port=callee_port,
            callee_location=callinfo["location"],
            leaves=callinfo["leaves"],
            type_interval=callinfo["type_interval"],
            titos=titos,
            annotations=callinfo.get("annotations", []),
        )
        self._generate_transitive_trace_frames(run, call_tf, leaf_ids)
        return call_tf

    def _generate_transitive_trace_frames(
        self, run: Run, start_frame: TraceFrame, leaf_ids: Set[int]
    ):
        """Generates all trace reachable from start_frame, provided they contain a
        leaf_id from the initial set of leaf_ids."""

        kind = start_frame.kind
        queue = [(start_frame, leaf_ids)]
        while len(queue) > 0:
            frame, leaves = queue.pop()
            if len(leaves) == 0:
                continue

            frame_id = frame.id.local_id
            if frame_id in self.visited_frames:
                leaves = leaves - self.visited_frames[frame_id]
                if len(leaves) == 0:
                    continue
                else:
                    self.visited_frames[frame_id].update(leaves)
            else:
                self.visited_frames[frame_id] = leaves

            next_frames = self._get_or_populate_trace_frames(
                kind, run, frame.callee_id, caller_port=frame.callee_port
            )
            queue.extend(
                [
                    # pyre-fixme[16]: `_Alias` has no attribute `intersection`.
                    (frame, Set.intersection(leaves, frame_leaves))
                    for (frame, frame_leaves) in next_frames
                ]
            )

    def _is_leaf_port(self, port: str) -> bool:
        return (
            port == "leaf"
            or port == "source"
            or port == "sink"
            or port.startswith("anchor:")
            or port.startswith("producer:")
        )

    def _get_or_populate_trace_frames(
        self, kind: TraceKind, run: Run, caller_id: DBID, caller_port: str
    ) -> List[Tuple[TraceFrame, Set[int]]]:  # TraceFrame, LeafIds
        if self.graph.has_trace_frames_with_caller(kind, caller_id, caller_port):
            return [
                (frame, self.graph.get_trace_frame_leaf_ids(frame))
                for frame in self.graph.get_trace_frames_from_caller(
                    kind, caller_id, caller_port
                )
            ]
        key = (self.graph.get_text(caller_id), caller_port)
        new = [
            self._generate_trace_frame(kind, run, e)
            for e in self.summary["trace_entries"][kind].pop(key, [])
        ]
        if len(new) == 0 and not self._is_leaf_port(key[1]):
            self.summary["missing_traces"][kind].add(key)
        return new

    def _generate_trace_frame(self, kind: TraceKind, run, entry):
        callee_location = entry["callee_location"]
        titos = self._generate_tito(entry["filename"], entry, entry["caller"])
        leaves = entry.get("leaves", None)
        if not leaves:
            leaves = (
                entry["sources"] if kind is TraceKind.POSTCONDITION else entry["sinks"]
            )
        return self._generate_raw_trace_frame(
            kind,
            run=run,
            filename=entry["filename"],
            caller=entry["caller"],
            caller_port=entry["caller_port"],
            callee=entry["callee"],
            callee_port=entry["callee_port"],
            callee_location=callee_location,
            titos=titos,
            leaves=leaves,
            type_interval=entry["type_interval"],
            annotations=entry.get("annotations", []),
        )

    def _generate_raw_trace_frame(
        self,
        kind,
        run,
        filename,
        caller,
        caller_port,
        callee,
        callee_port,
        callee_location,
        titos,
        leaves,
        type_interval,
        annotations,
    ):
        leaf_kind = (
            SharedTextKind.SOURCE
            if kind is TraceKind.POSTCONDITION
            else SharedTextKind.SINK
        )
        lb, ub, preserves_type_context = self._get_interval(type_interval)
        caller_record = self._get_shared_text(SharedTextKind.CALLABLE, caller)
        callee_record = self._get_shared_text(SharedTextKind.CALLABLE, callee)
        filename_record = self._get_shared_text(SharedTextKind.FILENAME, filename)
        trace_frame = TraceFrame.Record(
            id=DBID(),
            kind=kind,
            caller_id=caller_record.id,
            caller_port=caller_port,
            callee_id=callee_record.id,
            callee_port=callee_port,
            callee_location=SourceLocation(
                callee_location["line"],
                callee_location["start"],
                callee_location["end"],
            ),
            filename_id=filename_record.id,
            titos=titos,
            run_id=run.id,
            preserves_type_context=preserves_type_context,
            type_interval_lower=lb,
            type_interval_upper=ub,
            migrated_id=None,
        )

        leaf_ids = set()
        for (leaf, depth) in leaves:
            leaf_record = self._get_shared_text(leaf_kind, leaf)
            leaf_ids.add(leaf_record.id.local_id)
            self.graph.add_trace_frame_leaf_assoc(trace_frame, leaf_record, depth)

        self.graph.add_trace_frame(trace_frame)
        self._generate_trace_annotations(
            trace_frame.id, filename, caller, annotations, run
        )
        return trace_frame, leaf_ids

    def _generate_issue_feature_contents(self, issue, feature):
        # Generates a synthetic feature from the extra/feature
        features = set()
        for key in feature:
            value = feature[key]
            if isinstance(value, str) and value:
                features.add(key + ":" + value)
            else:
                features.add(key)
        return features

    def _get_interval(self, ti) -> Tuple[Optional[int], Optional[int], bool]:
        lower = ti.get("start", None)
        upper = ti.get("finish", None)
        preserves_type_context = ti.get("preserves_type_context", False)
        return (lower, upper, preserves_type_context)

    def _generate_trace_annotations(
        self, parent_id, parent_filename, parent_caller, annotations, run
    ) -> None:
        for annotation in annotations:
            location = annotation["location"]
            leaf_kind = annotation.get("leaf_kind")
            annotation_record = TraceFrameAnnotation.Record(
                id=DBID(),
                trace_frame_id=parent_id,
                location=SourceLocation(
                    location["line"], location["start"], location["end"]
                ),
                kind=annotation["kind"],
                message=annotation["msg"],
                leaf_id=(
                    None
                    if not leaf_kind
                    else self._get_shared_text(SharedTextKind.SINK, leaf_kind).id
                ),
                link=annotation.get("link"),
                trace_key=annotation.get("trace_key"),
            )
            self.graph.add_trace_annotation(annotation_record)

            traces = annotation.get("preconditions", [])
            for trace in traces:
                tf = self._generate_annotation_precondition(
                    run, parent_filename, parent_caller, trace, annotation
                )
                self.graph.add_trace_frame_annotation_trace_frame_assoc(
                    annotation_record, tf
                )

    def _generate_annotation_precondition(
        self, run, parent_filename, parent_caller, trace, annotation
    ):
        # Generates the first-hop trace frames from the annotation and
        # all dependencies of these preconditions. If this gets called, it is
        # assumed that the annotation leads to traces, and that the leaf kind
        # and depth are specified.
        callee = trace["callee"]
        callee_port = trace["port"]
        call_tf, leaf_ids = self._generate_raw_trace_frame(
            TraceKind.PRECONDITION,
            run,
            parent_filename,
            parent_caller,
            "root",
            callee,
            callee_port,
            annotation["location"],
            [],  # no additional positions in an annotation's root traces
            [(annotation["leaf_kind"], annotation["leaf_depth"])],
            annotation["type_interval"],
            [],  # no more annotations for a precond coming from an annotation
        )
        self._generate_transitive_trace_frames(run, call_tf, leaf_ids)
        return call_tf

    def _get_issue_handle(self, entry):
        return entry["handle"]

    def _get_shared_text(self, kind, name):
        name = name[:SHARED_TEXT_LENGTH]
        shared_text = self.graph.get_shared_text(kind, name)
        if shared_text is None:
            shared_text = SharedText.Record(id=DBID(), contents=name, kind=kind)
            self.graph.add_shared_text(shared_text)
        return shared_text

    @staticmethod
    def get_location(entry, is_relative=False):
        line = entry["line"]
        if is_relative:
            line -= entry["callable_line"]
        return SourceLocation(line, entry["start"], entry["end"])

    @staticmethod
    def get_callable_location(entry):
        line = entry["callable_line"]
        return SourceLocation(line, entry["start"], entry["end"])
