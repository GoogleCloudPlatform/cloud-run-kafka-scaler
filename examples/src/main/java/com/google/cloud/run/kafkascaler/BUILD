#
# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Placeholder: load java_binary

package(default_visibility = [
    "//visibility:private",
])

java_binary(
    name = "example_consumer_binary",
    srcs = ["ExampleConsumer.java"],
    main_class = "google.cloud.run.kafkascaler.ExampleConsumer",
    runtime_deps = [
        "@maven//:com_google_cloud_hosted_kafka_managed_kafka_auth_login_handler",  # required for connecting to Managed Kafka
    ],
    deps = [
        "@maven//:org_apache_kafka_kafka_clients",
    ],
)
