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

# Runs a deterministic, scheduled workload against an OpenAI-compatible chat API
#
# The cases file is a JSON list. Each item must contain `id`, `send_after_ms`,
# `prompt`, and `max_tokens`. Requests are started after their configured delay and
# use streaming responses so curl's time-to-first-byte can approximate TTFT.
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

            let response = (
                do --ignore-errors {
                    (
                        ^curl --fail-with-body --silent --show-error --no-buffer
                            --output "/dev/null"
                            --write-out "%{http_code}\t%{time_starttransfer}\t%{time_total}"
                            --header "Content-Type: application/json"
                            --data-binary $body
                            $url
                    )
                } | complete
            )

            let fields = ($response.stdout | str trim | split row "\t")
            let has_metrics = (($fields | length) >= 3)
            let http_status = if $has_metrics {
                $fields.0 | into int
            } else {
                0
            }
            let ttft_ms = if $has_metrics {
                ($fields.1 | into float) * 1000
            } else {
                0.0
            }
            let total_ms = if $has_metrics {
                ($fields.2 | into float) * 1000
            } else {
                0.0
            }
            let success = ($response.exit_code == 0) and ($http_status == 200)

            {
                request_id: $entry.index
                case_id: ($request_case | get id)
                send_after_ms: $send_after_ms
                start_ms: ($start_offset_ms | math round --precision 1)
                first_byte_ms: (($start_offset_ms + $ttft_ms) | math round --precision 1)
                finish_ms: (($start_offset_ms + $total_ms) | math round --precision 1)
                ttft_ms: ($ttft_ms | math round --precision 1)
                total_ms: ($total_ms | math round --precision 1)
                max_tokens: ($request_case | get max_tokens)
                http_status: $http_status
                curl_exit_code: $response.exit_code
                success: $success
                error: (if $success { "" } else { $response.stderr | str trim })
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

    print ($results | select case_id send_after_ms first_byte_ms finish_ms)
    print ($summary | reject ttft total_latency)
    print "TTFT (milliseconds)"
    print $summary.ttft
    print "Total latency (milliseconds)"
    print $summary.total_latency

}
