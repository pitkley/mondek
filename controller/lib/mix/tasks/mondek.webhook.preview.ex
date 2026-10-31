# Copyright 2026 Pit Kleyersburg <pitkley@googlemail.com>
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Mondek.Webhook.Preview do
  use Mix.Task
  @shortdoc "Render a webhook document locally, without starting services or sending requests"

  def run(args) do
    Mix.Task.run("compile")

    {options, [], []} =
      OptionParser.parse(args, strict: [template: :string, input: :string, event: :string])

    document =
      if options[:input],
        do: Mondek.NotificationTemplate.load!(options[:input]),
        else: Map.fetch!(Mondek.WebhookNotification.examples(), options[:event] || "problem")

    template =
      case options[:template] do
        nil -> nil
        "teams" -> Mondek.NotificationTemplate.load!(Mondek.WebhookNotification.teams_path())
        path -> Mondek.NotificationTemplate.load!(path)
      end

    Mix.shell().info(Mondek.WebhookNotification.render!(template, document))
  rescue
    _ ->
      Mix.raise(
        "Cannot preview webhook: use --event problem|updated|recovered|closed|monitoring_lost|monitoring_restored, --template teams|PATH and/or --input DOCUMENT.json"
      )
  end
end
