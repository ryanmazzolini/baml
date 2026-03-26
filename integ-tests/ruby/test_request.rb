require 'minitest/autorun'
require 'minitest/reporters'

require_relative "baml_client/client"


b = Baml.Client

describe "Expose Request Tests" do
  it "test_expose_request_gpt4" do
    request = b.request.ExtractReceiptInfo(email: "test@email.com", reason: "curiosity")

    assert_equal request.body.json, {
      'model' => 'gpt-4o',
      'messages' => [
        {
          'role' => 'system',
          'content' => [
            {
              'type' => 'text',
              'text' => "Given the receipt below:\n\n```\ntest@email.com\n```\n\nAnswer in JSON using this schema:\n{\n  items: [\n    {\n      name: string,\n      description: string or null,\n      quantity: int,\n      price: float,\n    }\n  ],\n  total_cost: float or null,\n  venue: \"barisa\" or \"ox_burger\",\n}"
            }
          ]
        }
      ]
    }
  end

  it "test_expose_request_gemini" do
    request = b.request.TestGeminiSystemAsChat(input: "Dr. Pepper")

    assert_equal request.body.json, {
      'system_instruction' => {
        'parts' => [{'text' => 'You are a helpful assistant'}]
      },
      'contents' => [
        {
          'parts' => [{'text' => 'Write a nice short story about Dr. Pepper. Keep it to 15 words or less.'}],
          'role' => 'user'
        }
      ],
      'safetySettings' => {
        'category' => 'HARM_CATEGORY_HATE_SPEECH',
        'threshold' => 'BLOCK_LOW_AND_ABOVE'
      }
    }
  end

  it "test_expose_request_fallback" do
    # First client in strategy is GPT4Turbo
    request = b.request.TestFallbackStrategy(input: "Dr. Pepper")

    assert_equal request.body.json, {
      'model' => 'gpt-4-turbo',
      'messages' => [
        {
          'role' => 'system',
          'content' => [{
            'type' => 'text',
            'text' => 'You are a helpful assistant.'
          }]
        },
        {
          'role' => 'user',
          'content' => [{
            'type' => 'text',
            'text' => 'Write a nice short story about Dr. Pepper'
          }]
        }
      ]
    }
  end

  it "test_expose_request_round_robin" do
    # Round-robin counter is shared across tests, so we can't predict which
    # client comes first. Assert it's one of the valid round-robin clients.
    request = b.request.TestRoundRobinStrategy(input: "Dr. Pepper")
    body = request.body.json
    model = body['model']

    assert_includes ['claude-3-haiku-20240307', 'gpt-4o-mini'], model,
      "Expected round-robin model to be Claude or GPT, got: #{model}"

    # Verify the prompt content regardless of which client was selected
    messages = body['messages']
    all_text = messages.flat_map { |m| Array(m['content']).map { |c| c['text'] } }
    system_text = body['system'] ? body['system'].map { |s| s['text'] } : messages.select { |m| m['role'] == 'system' }.flat_map { |m| Array(m['content']).map { |c| c['text'] } }

    assert all_text.any? { |t| t.include?('Dr. Pepper') }, "Expected prompt to mention Dr. Pepper"
    assert system_text.any? { |t| t.include?('helpful assistant') }, "Expected system prompt about helpful assistant"
  end

  it "test_expose_request_gpt4_stream" do
    request = b.stream_request.ExtractReceiptInfo(email: "test@email.com", reason: "curiosity")

    assert_equal request.body.json, {
      'model' => 'gpt-4o',
      'stream' => true,
      'stream_options' => {
        'include_usage' => true
      },
      'messages' => [
        {
          'role' => 'system',
          'content' => [
            {
              'type' => 'text',
              'text' => "Given the receipt below:\n\n```\ntest@email.com\n```\n\nAnswer in JSON using this schema:\n{\n  items: [\n    {\n      name: string,\n      description: string or null,\n      quantity: int,\n      price: float,\n    }\n  ],\n  total_cost: float or null,\n  venue: \"barisa\" or \"ox_burger\",\n}"
            }
          ]
        }
      ]
    }
  end
end
