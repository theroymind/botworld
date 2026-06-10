-- Cross-axis alignment enums for the stack containers. A vstack places
-- narrower-than-inner children horizontally (align); an hstack places
-- shorter-than-row children vertically (align_v). The default in both axes is
-- the start edge, matching the solver's historical behaviour.
return {
  -- vstack `align`: horizontal placement of narrower children.
  START = "start",
  CENTER = "center",
  END = "end",
  -- hstack `align_v`: vertical placement of shorter children.
  TOP = "top",
  MIDDLE = "center",
  BOTTOM = "bottom",
}
