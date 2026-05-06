import { sourceColor, sourceLabel } from "../lib/sources";

export function SourceDot(props: { kind: string; class?: string }) {
  return (
    <span
      class={`source-dot inline-block shrink-0 rounded-full ${props.class ?? "size-2"}`}
      style={{ "background-color": sourceColor(props.kind) }}
      aria-hidden="true"
    />
  );
}

export function SourceChip(props: { kind: string }) {
  return (
    <span class="source-chip inline-flex items-center gap-1.5 rounded-full px-2 py-0.5 text-[11px] font-medium text-text-muted">
      <SourceDot kind={props.kind} class="size-1.5" />
      {sourceLabel(props.kind)}
    </span>
  );
}
