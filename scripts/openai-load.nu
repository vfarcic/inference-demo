#!/usr/bin/env nu

# Requires curl. The consuming project is responsible for pinning it.

def openai_load_percentile [values, percentile] {

    let sorted = ($values | sort)
    let index = (
        (((($sorted | length) - 1) * $percentile / 100)
            | math round
            | into int)
    )

    $sorted | get $index

}

def openai_load_stats [values] {

    if ($values | is-empty) {
        null
    } else {
        {
            min_ms: ($values | math min | math round --precision 1)
            average_ms: ($values | math avg | math round --precision 1)
            p50_ms: (openai_load_percentile $values 50 | math round --precision 1)
            p95_ms: (openai_load_percentile $values 95 | math round --precision 1)
            p99_ms: (openai_load_percentile $values 99 | math round --precision 1)
            max_ms: ($values | math max | math round --precision 1)
        }
    }

}

def openai_load_has_token [line: string] {

    if not ($line | str starts-with "data: ") or ($line == "data: [DONE]") {
        false
    } else {
        try {
            let event = ($line | str replace "data: " "" | from json)
            let delta = $event.choices.0.delta
            let content = ($delta.content? | default "")
            let reasoning = ($delta.reasoning? | default "")
            let reasoning_content = ($delta.reasoning_content? | default "")

            ((not ($content | is-empty)) or (not ($reasoning | is-empty)) or (not ($reasoning_content | is-empty)))
        } catch {
            false
        }
    }

}

# Runs a deterministic, scheduled workload against an OpenAI-compatible chat API
#
# The cases file is a JSON list. Each item must contain `id`, `send_after_ms`,
# `prompt`, and `max_tokens`. Requests are started after their configured delay and
# use streaming responses so the first non-empty completion token can be timed.
#
# Example:
# > main run openai_load http://model.example/v1/chat/completions \
#     --model qwen3-8b --cases demo/batching-cases.json \
#     --concurrency 8 --output tmp/batching-load.json
def "main run openai_load" [
    url: string               # OpenAI-compatible chat completions URL
    --model = ""              # Served model name
    --cases = ""              # JSON workload definition
    --concurrency = 0         # Client workers. Zero uses one worker per case
    --seed = 42               # Base deterministic model seed
    --output = ""             # Optional JSON report path
] {

    if $model == "" {
        print $"(ansi red_bold)--model is required.(ansi reset)"
        exit 1
    }

    if ($cases == "") or (not ($cases | path exists)) {
        print $"(ansi red_bold)($cases)(ansi reset) does not exist."
        exit 1
    }

    let workload = (open $cases)
    if ($workload | is-empty) {
        print $"(ansi red_bold)($cases)(ansi reset) contains no requests."
        exit 1
    }

    let worker_count = if $concurrency > 0 {
        $concurrency
    } else {
        $workload | length
    }

    let suite_started = (date now)
    let results = (
        $workload
        | enumerate
        | par-each --threads $worker_count --keep-order { |entry|
            let request_case = $entry.item
            let send_after_ms = ($request_case | get send_after_ms? | default 0)

            sleep ($send_after_ms * 1ms)

            let started = (date now)
            let start_offset_ms = (($started - $suite_started) / 1ms)
            let body = ({
                model: $model
                messages: [{
                    role: "user"
                    content: ($request_case | get prompt)
                }]
                temperature: 0
                seed: ($seed + $entry.index)
                max_tokens: ($request_case | get max_tokens)
                stream: true
            } | to json)

            let metrics_marker = "__OPENAI_LOAD_METRICS__"
            let write_out = ([
                "\n"
                $metrics_marker
                "\t%{http_code}\t%{time_total}\t%{exitcode}\t%{errormsg}"
            ] | str join)
            let streamed = (
                do --ignore-errors {
                    (
                        ^curl --fail-with-body --silent --show-error --no-buffer
                            -w $write_out
                            --header "Content-Type: application/json"
                            --data-binary $body
                            $url
                    )
                }
                | lines
                | each { |line|
                    {
                        line: $line
                        received_ms: (((date now) - $started) / 1ms)
                    }
                }
                | collect
            )

            let metrics_rows = (
                $streamed
                | where { |row| $row.line | str starts-with $metrics_marker }
            )
            let has_metrics = not ($metrics_rows | is-empty)
            let fields = if $has_metrics {
                $metrics_rows | last | get line | split row "\t"
            } else {
                []
            }
            let http_status = if $has_metrics {
                $fields.1 | into int
            } else {
                0
            }
            let total_ms = if $has_metrics {
                ($fields.2 | into float) * 1000
            } else {
                0.0
            }
            let curl_exit_code = if $has_metrics {
                $fields.3 | into int
            } else {
                1
            }
            let token_rows = ($streamed | where { |row| openai_load_has_token $row.line })
            let ttft_ms = if ($token_rows | is-empty) {
                null
            } else {
                $token_rows | first | get received_ms
            }
            let stream_completed = ($streamed | any { |row| $row.line == "data: [DONE]" })
            let success = (
                ($curl_exit_code == 0)
                and ($http_status == 200)
                and (not ($token_rows | is-empty))
                and $stream_completed
            )
            let error = if $success {
                ""
            } else if $has_metrics and (($fields | length) >= 5) and (not ($fields.4 | is-empty)) {
                $fields | skip 4 | str join "\t"
            } else if not $stream_completed {
                "Streaming response ended before data: [DONE]."
            } else {
                "No non-empty streamed completion token received."
            }

            {
                request_id: $entry.index
                case_id: ($request_case | get id)
                send_after_ms: $send_after_ms
                start_ms: ($start_offset_ms | math round --precision 1)
                first_token_ms: (if $ttft_ms == null {
                    null
                } else {
                    ($start_offset_ms + $ttft_ms) | math round --precision 1
                })
                finish_ms: (($start_offset_ms + $total_ms) | math round --precision 1)
                ttft_ms: (if $ttft_ms == null {
                    null
                } else {
                    $ttft_ms | math round --precision 1
                })
                total_ms: ($total_ms | math round --precision 1)
                max_tokens: ($request_case | get max_tokens)
                http_status: $http_status
                curl_exit_code: $curl_exit_code
                success: $success
                error: $error
            }
        }
    )

    let suite_elapsed_ms = (((date now) - $suite_started) / 1ms)
    let successful = ($results | where success == true)
    let failed = ($results | where success == false)
    let requests_per_second = if $suite_elapsed_ms > 0 {
        ($successful | length) / ($suite_elapsed_ms / 1000)
    } else {
        0.0
    }
    let summary = {
        requests: ($results | length)
        successes: ($successful | length)
        failures: ($failed | length)
        elapsed_ms: ($suite_elapsed_ms | math round --precision 1)
        requests_per_second: ($requests_per_second | math round --precision 2)
        ttft: (openai_load_stats ($successful | get ttft_ms))
        total_latency: (openai_load_stats ($successful | get total_ms))
    }
    let report = {
        configuration: {
            url: $url
            model: $model
            cases: $cases
            concurrency: $worker_count
            seed: $seed
        }
        summary: $summary
        requests: $results
    }

    if $output != "" {
        let output_parent = ($output | path dirname)
        if ($output_parent != ".") and (not ($output_parent | path exists)) {
            mkdir $output_parent
        }
        $report | to json --indent 2 | save --force $output
    }

    print ($results | select case_id send_after_ms first_token_ms finish_ms)
    print ($summary | reject ttft total_latency)
    print "TTFT (milliseconds)"
    print $summary.ttft
    print "Total latency (milliseconds)"
    print $summary.total_latency

}
