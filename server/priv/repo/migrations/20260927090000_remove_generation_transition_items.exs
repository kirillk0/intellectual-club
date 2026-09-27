defmodule IntellectualClub.Repo.Migrations.RemoveGenerationTransitionItems do
  @moduledoc """
  Removes legacy operational generation-transition receipts from canonical traces.
  """

  use Ecto.Migration

  def up do
    execute("""
    WITH transition_items AS MATERIALIZED (
      SELECT item.id
      FROM chat_message_items AS item
      JOIN chat_message_contents AS content
        ON content.chat_message_item_id = item.id
      WHERE item.type = 'other'
      GROUP BY item.id
      HAVING count(*) = 1
         AND bool_and(
           content.sequence = 1
           AND content.kind = 'opaque'
           AND jsonb_typeof(content.content_json) = 'object'
           AND content.content_json - 'generation_transition' = '{}'::jsonb
           AND jsonb_typeof(content.content_json -> 'generation_transition') = 'object'
           AND (content.content_json -> 'generation_transition') ?&
                 ARRAY['kind', 'steering', 'next_step_id', 'next_sequence']
           AND (((((content.content_json -> 'generation_transition') - 'kind') - 'steering') -
                 'next_step_id') - 'next_sequence') - 'steering_operation_id' = '{}'::jsonb
           AND content.content_json -> 'generation_transition' ->> 'kind' IN
                 ('retry', 'steering', 'queued_steering', 'followup', 'queued_followup')
           AND jsonb_typeof(
                 content.content_json -> 'generation_transition' -> 'steering'
               ) = 'array'
           AND jsonb_typeof(
                 content.content_json -> 'generation_transition' -> 'next_step_id'
               ) = 'number'
           AND jsonb_typeof(
                 content.content_json -> 'generation_transition' -> 'next_sequence'
               ) = 'number'
         )
    ), deleted_contents AS (
      DELETE FROM chat_message_contents AS content
      USING transition_items
      WHERE content.chat_message_item_id = transition_items.id
      RETURNING content.chat_message_item_id
    )
    DELETE FROM chat_message_items AS item
    USING deleted_contents
    WHERE item.id = deleted_contents.chat_message_item_id
    """)
  end

  def down do
    :ok
  end
end
