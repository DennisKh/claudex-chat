defmodule ClaudexChat.Repo.Migrations.AddResultToToolCalls do
  use Ecto.Migration

  # A call answered before `result` existed kept only its text output and its
  # status. This rebuilds the tool_result that was sent from those two, so
  # every answered call replays the same way.
  def up do
    execute """
    UPDATE messages
    SET tool_calls = (
      SELECT jsonb_agg(
        CASE
          WHEN call->>'status' <> 'pending' AND call->>'output' IS NOT NULL THEN
            call || jsonb_build_object('result', jsonb_build_object(
              'type', 'tool_result',
              'tool_use_id', call->>'call_id',
              'content', call->>'output',
              'is_error', call->>'status' IN ('denied', 'failed')))
          ELSE call
        END
        ORDER BY position)
      FROM jsonb_array_elements(tool_calls) WITH ORDINALITY AS calls(call, position))
    WHERE jsonb_array_length(tool_calls) > 0
    """
  end

  def down do
    execute """
    UPDATE messages
    SET tool_calls = (
      SELECT jsonb_agg(call - 'result' ORDER BY position)
      FROM jsonb_array_elements(tool_calls) WITH ORDINALITY AS calls(call, position))
    WHERE jsonb_array_length(tool_calls) > 0
    """
  end
end
