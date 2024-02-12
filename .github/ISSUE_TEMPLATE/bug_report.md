---
name: 🐛 Bug report
about: Create a report to help us improve
title: ''
labels: 'bug, needs-review'
assignees: ''

---

# Get your issue reviewed faster

To help us understand the problem more quickly, please do the following:

1. Run the `kata-collect-data.sh` script, which is installed as part of Kata Containers
   or `kata-containers.collect-data`, which is installed as part of the Kata Containers
   snapcraft package.
   ```sh
   $ sudo kata-collect-data.sh > /tmp/kata.log
   ```
   or
   ```sh
   $ sudo kata-containers.collect-data > /tmp/kata.log
   ```
1. Review the output file (`/tmp/kata.log`) to ensure it doesn't
   contain any private / sensitive information
1. Paste the *entire* contents of the file into this issue as a comment
   (the script generates markdown format output).

The information provided will help us to understand the problem more quickly
so saves time for both of us! :smile:

# Description of problem

(replace this text with the list of steps you followed)

# Expected result

(replace this text with an explanation of what you thought would happen)

# Actual result

(replace this text with an explanation of what actually happened)

# Further information

(replace this text with any extra information you think might be useful)

# Kata Containers survey

Please consider taking the survey to help us help you: https://openinfrafoundation.formstack.com/forms/kata_containers_user_survey
