# frozen_string_literal: true

require 'spec_helper'
require 'fakefs/spec_helpers'
module LicenseFinder
  describe Gradle do
    let(:options) { {} }

    subject { Gradle.new(options.merge(project_path: Pathname('/fake/path'))) }

    let(:content) { [] }

    it_behaves_like 'a PackageManager'

    describe '#current_packages' do
      before do
        allow(Dir).to receive(:chdir).with(Pathname('/fake/path')).and_return(['', '', cmd_success])
        dependencies = double(:subject_dependency_file, dependencies: content)
        expect(GradleDependencyFinder).to receive(:new).and_return(dependencies)
      end

      it 'uses the gradle wrapper, if present' do
        subject = Gradle.new(project_path: Pathname('features/fixtures/gradle-wrapper'))
        expect(Dir).to receive(:chdir).with(Pathname('features/fixtures/gradle-wrapper')).and_call_original
        allow(SharedHelpers::Cmd).to receive(:run).and_return(['/usr/local/bin/gradle

BUILD SUCCESSFUL in 0s
1 actionable task: 1 executed', '', cmd_success])
        if Platform.windows?
          expect(subject.package_management_command).to eq('gradlew.bat')
        else
          expect(subject.package_management_command).to eq('./gradlew')
        end
        subject.current_packages
      end

      it 'uses custom subject command, if provided' do
        subject = Gradle.new(gradle_command: 'subjectfoo', project_path: Pathname('/fake/path'))
        expect(Dir).to receive(:chdir).with(Pathname('/fake/path')) { |&block| block.call }
        expect(SharedHelpers::Cmd).to receive(:run).with('subjectfoo downloadLicenses').and_return(['', '', cmd_success])
        subject.current_packages
      end

      it 'sets the working directory to project_path, if provided' do
        subject = Gradle.new(project_path: Pathname('/Users/foo/bar'))
        expect(Dir).to receive(:chdir).with(Pathname('/Users/foo/bar')) { |&block| block.call }
        if Platform.windows?
          expect(SharedHelpers::Cmd).to receive(:run).with('gradle.bat downloadLicenses').and_return(['', '', cmd_success])
        else
          expect(SharedHelpers::Cmd).to receive(:run).with('gradle downloadLicenses').and_return(['', '', cmd_success])
        end
        subject.current_packages
      end

      context 'when dependencies are found' do
        let(:content) do
          [
            "<dependencies>
              <dependency name='org.springframework:spring-aop:4.0.1.RELEASE'></dependency>
              <dependency name='org.springframework:spring-core:4.0.1.RELEASE'></dependency>
            </dependencies>"
          ]
        end

        it 'lists all dependencies' do
          expect(subject.current_packages.map(&:name)).to eq %w[spring-aop spring-core]
        end

        context 'when gradle group ids option is enabled' do
          let(:options) { { gradle_include_groups: true } }

          it 'lists the dependencies with the group id' do
            expect(subject.current_packages.map(&:name)).to eq ['org.springframework:spring-aop', 'org.springframework:spring-core']
          end
        end
      end

      context 'when multiple licenses exist' do
        let(:content) do
          [
            "<dependencies>
               <dependency name=''>
                 <license name='License 1'/>
                 <license name='License 2'/>
               </dependency>
            </dependencies>"
          ]
        end

        it 'lists all dependencies' do
          expect(subject.current_packages.first.licenses.map(&:name)).to eq ['License 1', 'License 2']
        end
      end

      context 'when no licenses exist' do
        let(:content) do
          [
            "<dependencies>
              <dependency name=''></dependency>
            </dependencies>"
          ]
        end

        it 'returns unknown' do
          expect(subject.current_packages.first.licenses.map(&:name)).to eq ['unknown']
        end
      end

      context 'when multiple license files exist' do
        let(:content) do
          [
            "<dependencies>
              <dependency name='junit:junit:4.12'></dependency>
            </dependencies>",
            "<dependencies>
              <dependency name='org.mockito:mockito-core:1.9.5'></dependency>
            </dependencies>"
          ]
        end

        it 'lists all dependencies' do
          expect(subject.current_packages.map(&:name)).to eq %w[junit mockito-core]
        end

        context 'and there are duplicate dependencies' do
          let(:content) do
            [
              "<dependencies>
                 <dependency name='junit:junit:4.12'></dependency>
               </dependencies>",
              "<dependencies>
                 <dependency name='org.mockito:mockito-core:1.9.5'></dependency>
               </dependencies>",
              "<dependencies>
                 <dependency name='org.mockito:mockito-core:1.9.5'></dependency>
               </dependencies>"
            ]
          end

          it 'removes duplicates' do
            expect(subject.current_packages.map(&:name)).to eq %w[junit mockito-core]
          end
        end
      end
    end

    describe '#active?' do
      include FakeFS::SpecHelpers

      it 'return true if build.gradle exists' do
        FakeFS do
          FileUtils.mkdir_p '/fake/path'
          FileUtils.touch '/fake/path/build.gradle'

          expect(subject.active?).to be true
        end
      end

      context "when there's no build.gradle or build.gradle.kts" do
        it 'returns false' do
          expect(subject.active?).to be false
        end
      end

      context "when there's build.gradle.kts" do
        it 'return true' do
          FakeFS do
            FileUtils.mkdir_p '/fake/path'
            FileUtils.touch '/fake/path/build.gradle.kts'

            expect(subject.active?).to be true
          end
        end
      end

      context "when there's a settings.gradle" do
        it 'uses the build.gradle referenced inside' do
          SETTINGS_DOT_GRADLE = <<-GRADLE
rootProject.buildFileName = 'build-alt.gradle'
          GRADLE

          FakeFS do
            FileUtils.mkdir_p '/fake/path'
            File.open('/fake/path/settings.gradle', 'w') do |file|
              file.write SETTINGS_DOT_GRADLE
            end
            FileUtils.touch '/fake/path/build-alt.gradle'

            expect(subject.active?).to be true
          end
        end
      end
    end

    describe '#subprojects' do
      before do
        allow(File).to receive(:exist?).with('/fake/path/./gradlew').and_return true
        allow(Dir).to receive(:chdir).with(Pathname('/fake/path')).and_yield
      end

      let(:gradle_properties_output) do
        "subprojects: [project ':submodule-1', project ':submodule-2']\n"
      end

      context 'when gradle project contains subprojects' do
        let(:subproject_dirs) do
          <<-TEXT
projectDir: /workspace/LicenseFinder/spec/fixtures/gradle-with-subprojects/submodule-1
projectDir: /workspace/LicenseFinder/spec/fixtures/gradle-with-subprojects/submodule-2
          TEXT
        end


        it 'returns all subprojects' do
          expect(SharedHelpers::Cmd).to receive(:run).with("./gradlew properties | grep 'subprojects: '").and_return([gradle_properties_output, nil, cmd_success])
          expect(SharedHelpers::Cmd).to receive(:run).with("./gradlew :submodule-1:properties :submodule-2:properties | grep projectDir").and_return([subproject_dirs, nil, cmd_success])

          expect(subject.subprojects).to eq(%w[/workspace/LicenseFinder/spec/fixtures/gradle-with-subprojects/submodule-1 /workspace/LicenseFinder/spec/fixtures/gradle-with-subprojects/submodule-2])
        end
      end

      context 'when gradle project contains no subprojects' do
        let(:gradle_properties_output) do
          "subprojects: []\n"
        end

        it 'returns an empty array' do
          expect(SharedHelpers::Cmd).to receive(:run).with("./gradlew properties | grep 'subprojects: '").and_return([gradle_properties_output, nil, cmd_success])

          expect(subject.subprojects).to eq([])
        end
      end

      context 'when subproject command fails' do

        it 'raises an error' do
          expect(SharedHelpers::Cmd).to receive(:run).with("./gradlew properties | grep 'subprojects: '").and_return([nil, 'error', cmd_failure])

          expect { subject.subprojects }.to raise_error(%r{Command '\./gradlew properties | grep 'subprojects: '' failed to execute: error})
        end
      end

      context 'when subproject path command fails' do
        it 'raises an error' do
          expect(SharedHelpers::Cmd).to receive(:run).with("./gradlew properties | grep 'subprojects: '").and_return([gradle_properties_output, nil, cmd_success])
          expect(SharedHelpers::Cmd).to receive(:run).with("./gradlew :submodule-1:properties :submodule-2:properties | grep projectDir").and_return([nil, 'error', cmd_failure])

          expect { subject.subprojects }.to raise_error(%r{Command '\./gradlew :submodule-1:properties :submodule-2:properties \| grep projectDir' failed to execute: error})
        end
      end

    end
  end
end
