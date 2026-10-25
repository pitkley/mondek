# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule MondekWeb.NotificationRetry do
  @moduledoc "Bounded retry form drafts and feedback shared by incident and delivery views."

  def keep_draft(drafts, occurrences, id, reason)
      when is_binary(reason) and byte_size(reason) <= 2_000 do
    # Recovery restores text only; requesting another attempt remains an explicit submit.
    if String.valid?(reason) &&
         (map_size(drafts) < 100 || Map.has_key?(drafts, id)) &&
         Enum.any?(occurrences, &(&1["id"] == id && &1["can_retry"] == true)),
       do: Map.put(drafts, id, reason),
       else: drafts
  end

  def keep_draft(drafts, _occurrences, _id, _reason), do: drafts

  def success_message,
    do:
      "Notification retry requested. The original notification will be attempted again when eligible. Failure notifications respect acknowledgement and maintenance; incident closure notifications remain eligible."

  def error_message({:invalid, message}) when is_binary(message), do: message
  def error_message({:conflict, message}) when is_binary(message), do: message
  def error_message(message) when is_binary(message), do: message

  def error_message(:not_exhausted),
    do: "This notification is no longer exhausted. Review its current delivery status."

  def error_message(:delivery_in_progress),
    do:
      "The previous delivery job is still finishing. Wait briefly and review its status before retrying."

  def error_message(:superseded),
    do: "This notification no longer applies to the current incident and cannot be retried."

  def error_message(:not_found),
    do: "This record is no longer available. Reload the page to review current state."

  def error_message(_), do: "The change could not be saved. Check the values and try again."
end
