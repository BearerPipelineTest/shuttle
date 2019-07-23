# Copyright 2014 Square Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

require 'rails_helper'
RSpec.describe StashWebhookPinger do
  include Rails.application.routes.url_helpers

  let(:http_response_code) { 204 }
  let(:http_response) { Net::HTTPResponse.new(1.0, http_response_code, "OK") }

  before(:each) do
    allow(Kernel).to receive(:sleep)
    allow(HTTParty).to receive(:post)
  end

  describe "#perform" do
    subject { StashWebhookPinger.new }

    context "on_perform" do
      before(:each) do
        @commit = FactoryBot.create(:commit)
      end

      it "sends an http request to the project stash_webhook_url 10 times if one is defined" do
        url = "http://www.example.com"
        @commit.project.stash_webhook_url = url
        @commit.project.save!
        expect(HTTParty).to receive(:post).with(
                                "#{url}/#{@commit.revision}",
                                anything()
                            ).exactly(StashWebhookHelper::DEFAULT_NUM_TIMES).times.and_return(http_response)
        subject.perform(@commit.id)
      end

      it "should make sure that the commit is reloaded with the proper state" do
        url = "http://www.example.com"
        @commit.project.stash_webhook_url = url
        @commit.project.save!

        expect(HTTParty).to receive(:post) do |url, params|
          commit_state = JSON.parse(params[:body])['state']
          expected_state = @commit.ready? ? 'SUCCESSFUL' : 'INPROGRESS'
          expect(commit_state).to eql(expected_state)
          @commit.update_column :ready, !@commit.ready
        end.exactly(StashWebhookHelper::DEFAULT_NUM_TIMES).times.and_return(http_response)
        subject.perform(@commit.id)
      end

      it "doesnt send anything if no stash_webhook_url is defined on the project" do
        expect(@commit.project.stash_webhook_url).to be_blank
        expect(HTTParty).not_to receive(:post)
        subject.perform(@commit.id)
      end

      it "raises a Project::NotLinkedToAGitRepositoryError if project doesn't have a repository_url" do
        @commit.project.update! repository_url: nil
        expect(HTTParty).not_to receive(:post)
        expect { subject.perform(@commit.id) }.to raise_error(Project::NotLinkedToAGitRepositoryError)
      end

      context "with failure http response code" do
        let(:http_response_code) { 400 }

        it "when http returns failure" do
          url = "http://www.example.com"
          @commit.project.stash_webhook_url = url
          @commit.project.save!

          expect(HTTParty).to receive(:post).and_return(http_response)

          expect { subject.perform(@commit.id) }.to raise_error(RuntimeError, "[StashWebhookHelper] Failed to ping stash for commit #{@commit.id}, revision: #{@commit.revision}, code: #{http_response_code}")
        end
      end
    end

    context "on_create" do
      it "sends an http request to the project stash_webhook_url when a commit is first created" do
        @commit = FactoryBot.build(:commit, ready: false, loading: true)
        @url = "http://www.example.com"
        @commit.project.stash_webhook_url = @url
        @commit.project.save!

        expect(HTTParty).to receive(:post).with("#{@url}/#{@commit.revision}", hash_including(body: {
            key: "SHUTTLE-#{@commit.project.slug}",
            name: "SHUTTLE-#{@commit.project.slug}-#{@commit.revision_prefix}",
            url: project_commit_url(@commit.project,
                                    @commit,
                                    host: Shuttle::Configuration.default_url_options.host,
                                    port: Shuttle::Configuration.default_url_options['port'],
                                    protocol: Shuttle::Configuration.default_url_options['protocol'] || 'http'),
            state: 'INPROGRESS',
            description: 'Currently loading',
        }.to_json)).exactly(StashWebhookHelper::DEFAULT_NUM_TIMES).times.and_return(http_response)
        @commit.save!
      end
    end
  end

  context "on_update" do
    before(:each) do
      expect(HTTParty).to receive(:post).exactly(StashWebhookHelper::DEFAULT_NUM_TIMES).times.and_return(http_response)

      @commit = FactoryBot.build(:commit, ready: false, loading: true)
      @url = "http://www.example.com"
      @commit.project.stash_webhook_url = @url
      @commit.project.save!
      @commit.save!
    end

    it "sends an request when the commit loading state changes" do
      expect(HTTParty).to receive(:post).with("#{@url}/#{@commit.revision}", hash_including(body: {
          key: "SHUTTLE-#{@commit.project.slug}",
          name: "SHUTTLE-#{@commit.project.slug}-#{@commit.revision_prefix}",
          url: project_commit_url(@commit.project,
                                  @commit,
                                  host: Shuttle::Configuration.default_url_options.host,
                                  port: Shuttle::Configuration.default_url_options['port'],
                                  protocol: Shuttle::Configuration.default_url_options['protocol'] || 'http'),
          state: 'INPROGRESS',
          description: 'Currently translating',
      }.to_json)).exactly(StashWebhookHelper::DEFAULT_NUM_TIMES).times.and_return(http_response)

      @commit.loading = false
      # force commit not to be ready
      @commit.keys << FactoryBot.create(:key, project: @commit.project)
      FactoryBot.create :translation, key: @commit.keys.first, copy: nil
      @commit.save!
    end

    it "sends an request when the commit ready state changes" do
      expect(HTTParty).to receive(:post).with("#{@url}/#{@commit.revision}", hash_including(body: {
          key: "SHUTTLE-#{@commit.project.slug}",
          name: "SHUTTLE-#{@commit.project.slug}-#{@commit.revision_prefix}",
          url: project_commit_url(@commit.project,
                                  @commit,
                                  host: Shuttle::Configuration.default_url_options.host,
                                  port: Shuttle::Configuration.default_url_options['port'],
                                  protocol: Shuttle::Configuration.default_url_options['protocol'] || 'http'),
          state: 'SUCCESSFUL',
          description: 'Translations completed',
      }.to_json)).exactly(StashWebhookHelper::DEFAULT_NUM_TIMES).times.and_return(http_response)
      @commit.loading = false
      @commit.ready = true # redundant since CSR will do this anyway
      @commit.save!
    end
  end
end
