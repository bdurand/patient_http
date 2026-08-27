# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::CompletionExecutor do
  let(:executor) { described_class.new(threads: 2) }

  after do
    executor.shutdown(timeout: 1)
  end

  describe "#enqueue" do
    it "runs jobs on a named completion worker thread" do
      thread_names = Concurrent::Array.new
      latch = Concurrent::CountDownLatch.new(2)

      2.times do
        executor.enqueue(lambda do
          thread_names << Thread.current.name
          latch.count_down
        end)
      end

      expect(latch.wait(2)).to be(true)
      expect(thread_names.size).to eq(2)
      thread_names.each do |name|
        expect(name).to match(/\Apatient-http-completion-\d+\z/)
      end
    end

    it "raises ClosedQueueError after shutdown" do
      executor.shutdown(timeout: 1)

      expect { executor.enqueue(-> {}) }.to raise_error(ClosedQueueError)
    end

    it "keeps running after a job raises" do
      results = Concurrent::Array.new
      latch = Concurrent::CountDownLatch.new(1)
      quiet_executor = described_class.new(threads: 1, logger: Logger.new(StringIO.new))

      begin
        quiet_executor.enqueue(-> { raise "boom" })
        quiet_executor.enqueue(lambda do
          results << :ok
          latch.count_down
        end)

        expect(latch.wait(2)).to be(true)
        expect(results).to eq([:ok])
      ensure
        quiet_executor.shutdown(timeout: 1)
      end
    end
  end

  describe "#idle?" do
    it "is idle with no jobs" do
      expect(executor.idle?).to be(true)
    end

    it "is not idle while a job is queued or running" do
      release = Concurrent::CountDownLatch.new(1)
      running = Concurrent::CountDownLatch.new(1)

      executor.enqueue(lambda do
        running.count_down
        release.wait(2)
      end)

      expect(running.wait(2)).to be(true)
      expect(executor.idle?).to be(false)

      release.count_down
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      Thread.pass until executor.idle? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      expect(executor.idle?).to be(true)
    end
  end

  describe "#worker_thread?" do
    it "identifies its own worker threads" do
      result = Concurrent::AtomicBoolean.new(false)
      latch = Concurrent::CountDownLatch.new(1)

      executor.enqueue(lambda do
        result.value = executor.worker_thread?
        latch.count_down
      end)

      expect(latch.wait(2)).to be(true)
      expect(result.value).to be(true)
      expect(executor.worker_thread?).to be(false)
    end
  end

  describe "#shutdown" do
    it "drains queued jobs before the workers exit" do
      results = Concurrent::Array.new
      single_thread = described_class.new(threads: 1)

      10.times { |i| single_thread.enqueue(-> { results << i }) }
      single_thread.shutdown(timeout: 2)

      expect(results.sort).to eq((0..9).to_a)
      expect(single_thread.idle?).to be(true)
    end

    it "kills a worker stuck past the deadline" do
      stuck = described_class.new(threads: 1)
      running = Concurrent::CountDownLatch.new(1)

      stuck.enqueue(lambda do
        running.count_down
        sleep(30)
      end)

      expect(running.wait(2)).to be(true)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stuck.shutdown(timeout: 0.2)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 5
    end

    it "is safe to call more than once" do
      executor.shutdown(timeout: 1)
      expect { executor.shutdown(timeout: 1) }.not_to raise_error
    end

    it "invokes the on_finished callback after each job" do
      finished_count = Concurrent::AtomicFixnum.new(0)
      callback_executor = described_class.new(threads: 1, on_finished: -> { finished_count.increment })

      begin
        3.times { callback_executor.enqueue(-> {}) }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        Thread.pass until finished_count.value == 3 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        expect(finished_count.value).to eq(3)
      ensure
        callback_executor.shutdown(timeout: 1)
      end
    end
  end
end
