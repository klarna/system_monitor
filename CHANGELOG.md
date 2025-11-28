# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - yyyy-mm-dd

## [2.3.1] - 2025-11-28

Codify the status quo that monitors are not run at terminate.

## [2.3.0] - 2025-11-25

Update proper
Improve ssl handling on OTP-26
Add callback function for retrieving password
Reduce risk for OOM
Avoid crashing on expected errors
Enable configurable ssl option when connecting
Fix warnings with OTP-27
Remove outdated docs
Allow configuring the node name
Update CI
Do not divide MaxProcs by 5

## [2.2.6] - 2023-02-06

CI updates
Remove usage of hut
Fix sql bug
Batch insert operations in postgres backend.
Improve failure handling
Update epgsql
Do not stop producer when restarting

## [2.2.5] - 2023-01-27

Start the producer from the supervisor

## [2.2.4] - 2022-12-05

Stop system monitor callback on system monitor stop

## [2.2.3] - 2022-12-01

Sort deltas before returning

## [2.2.2] - 2022-11-29

Do not query memory usage of processes that have huge message queues.

## [2.2.1] - 2022-09-12

Fixed a bug which could cause badrecord errors in system\_monitor\_top.

## [2.2.0] - 2021-11-05

Added support for configuring a module to use to send system_monitor events to
an external destination.

## [2.1.0] - 2021-10-20

Data format of system\_monitor\_top is changed to keep static data between
ticks. Since this gen server is started by a supervisor that allows for some
restarts, you can either let the server crash or stop+start this application.

## [2.0.0] - 2021-04-07

Replace Kafka backend with a configurable one that defaults into Postgres

## [1.0.0] - 2020-09-02

Initial version
