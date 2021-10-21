# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] - yyyy-mm-dd

## [2.1.0] - 2021-10-20

Data format of system\_monitor\_top is changed to keep static data between
ticks. Since this gen server is started by a supervisor that allows for some
restarts, you can either let the server crash or stop+start this application.

## [2.0.0] - 2021-04-07

Replace Kafka backend with a configurable one that defaults into Postgres

## [1.0.0] - 2020-09-02

Initial version
