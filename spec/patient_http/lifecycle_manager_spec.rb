# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::LifecycleManager do
  let(:lifecycle) { described_class.new }

  describe "#state" do
    it "starts in stopped state" do
      expect(lifecycle.state).to eq(:stopped)
    end
  end

  describe "state predicates" do
    context "when stopped" do
      it "returns true for stopped?" do
        expect(lifecycle.stopped?).to be true
      end

      it "returns false for other states" do
        expect(lifecycle.starting?).to be false
        expect(lifecycle.running?).to be false
        expect(lifecycle.draining?).to be false
        expect(lifecycle.stopping?).to be false
      end
    end

    context "when running" do
      before {
        lifecycle.start!
        lifecycle.running!
      }

      it "returns true for running?" do
        expect(lifecycle.running?).to be true
      end

      it "returns false for other states" do
        expect(lifecycle.stopped?).to be false
        expect(lifecycle.starting?).to be false
        expect(lifecycle.draining?).to be false
        expect(lifecycle.stopping?).to be false
      end
    end

    context "when draining" do
      before do
        lifecycle.start!
        lifecycle.running!
        lifecycle.drain!
      end

      it "returns true for draining?" do
        expect(lifecycle.draining?).to be true
      end
    end

    context "when stopping" do
      before do
        lifecycle.start!
        lifecycle.running!
        lifecycle.stop!
      end

      it "returns true for stopping?" do
        expect(lifecycle.stopping?).to be true
      end
    end
  end

  describe "#start!" do
    context "when stopped" do
      it "transitions to starting state" do
        expect(lifecycle.start!).to be true
        expect(lifecycle.starting?).to be true
      end
    end

    context "when already starting" do
      before { lifecycle.start! }

      it "returns false and stays in starting" do
        expect(lifecycle.start!).to be false
        expect(lifecycle.starting?).to be true
      end
    end

    context "when running" do
      before do
        lifecycle.start!
        lifecycle.running!
      end

      it "returns false" do
        expect(lifecycle.start!).to be false
        expect(lifecycle.running?).to be true
      end
    end

    context "when stopping" do
      before do
        lifecycle.start!
        lifecycle.running!
        lifecycle.stop!
      end

      it "returns false" do
        expect(lifecycle.start!).to be false
        expect(lifecycle.stopping?).to be true
      end
    end

    context "when draining" do
      before do
        lifecycle.start!
        lifecycle.running!
        lifecycle.drain!
      end

      it "returns false and stays in draining" do
        expect(lifecycle.start!).to be false
        expect(lifecycle.draining?).to be true
      end
    end
  end

  describe "#running!" do
    it "transitions to running state" do
      lifecycle.start!
      expect(lifecycle.running!).to be true
      expect(lifecycle.running?).to be true
    end

    it "does not transition unless starting" do
      lifecycle.start!
      lifecycle.running!
      lifecycle.stop!
      lifecycle.stopped!

      expect(lifecycle.running!).to be false
      expect(lifecycle.stopped?).to be true
    end
  end

  describe "#drain!" do
    context "when running" do
      before do
        lifecycle.start!
        lifecycle.running!
      end

      it "transitions to draining state" do
        expect(lifecycle.drain!).to be true
        expect(lifecycle.draining?).to be true
      end
    end

    context "when not running" do
      it "returns false" do
        expect(lifecycle.drain!).to be false
        expect(lifecycle.stopped?).to be true
      end
    end
  end

  describe "#stop!" do
    context "when running" do
      before do
        lifecycle.start!
        lifecycle.running!
      end

      it "transitions to stopping state" do
        expect(lifecycle.stop!).to be true
        expect(lifecycle.stopping?).to be true
      end

      it "signals shutdown" do
        lifecycle.stop!
        expect(lifecycle.shutdown_signaled?).to be true
      end
    end

    context "when draining" do
      before do
        lifecycle.start!
        lifecycle.running!
        lifecycle.drain!
      end

      it "transitions to stopping state" do
        expect(lifecycle.stop!).to be true
        expect(lifecycle.stopping?).to be true
      end
    end

    context "when stopped" do
      it "returns false" do
        expect(lifecycle.stop!).to be false
        expect(lifecycle.stopped?).to be true
      end
    end

    context "when starting" do
      before { lifecycle.start! }

      it "returns false" do
        expect(lifecycle.stop!).to be false
        expect(lifecycle.starting?).to be true
      end
    end
  end

  describe "#stopped!" do
    it "transitions to stopped state" do
      lifecycle.start!
      lifecycle.running!
      lifecycle.stop!
      lifecycle.stopped!
      expect(lifecycle.stopped?).to be true
    end
  end

  describe "#reactor_ready!" do
    it "signals reactor ready" do
      lifecycle.reactor_ready!
      # Should not block
      lifecycle.wait_for_reactor
    end
  end

  describe "#wait_for_running" do
    it "returns true immediately if already running" do
      lifecycle.start!
      lifecycle.running!
      expect(lifecycle.wait_for_running(timeout: 0.01)).to be true
    end

    it "returns false if timeout reached before running" do
      expect(lifecycle.wait_for_running(timeout: 0.01)).to be false
    end
  end

  describe "#wait_for_condition" do
    it "returns true when block yields true" do
      result = lifecycle.wait_for_condition(timeout: 0.1) { true }
      expect(result).to be true
    end

    it "returns false when timeout reached" do
      result = lifecycle.wait_for_condition(timeout: 0.01) { false }
      expect(result).to be false
    end
  end

  describe "#shutdown_signaled?" do
    it "returns false initially" do
      expect(lifecycle.shutdown_signaled?).to be false
    end

    it "returns true after stop!" do
      lifecycle.start!
      lifecycle.running!
      lifecycle.stop!
      expect(lifecycle.shutdown_signaled?).to be true
    end
  end
end
