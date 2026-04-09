# Contributors & Attribution

## Original TimeOverflow Platform

**TimeOverflow** is an open-source timebanking management system created and maintained by [Coopdevs](https://coopdevs.org/) and its community of contributors.

- **Repository:** https://github.com/coopdevs/timeoverflow
- **Website:** https://www.timeoverflow.org
- **License:** GNU Affero General Public License v3.0 (AGPL-3.0)

All credit for the core TimeOverflow platform — including its data model, business logic, user interface, authentication system, double-entry accounting, and all original source code — belongs to the Coopdevs team and the TimeOverflow contributors.

### Original Authors & Contributors

See the full list of contributors at:
https://github.com/coopdevs/timeoverflow/graphs/contributors

Key contributors to the original project include (but are not limited to) the members of the Coopdevs cooperative and all individuals who have contributed to the TimeOverflow repository since its creation in 2012.

---

## Federation API Extension

The Federation API layer in this fork was developed to enable cross-platform interoperability between TimeOverflow and external timebanking platforms (such as Project NEXUS).

**Fork maintainer:** Jasper Ford (https://github.com/jasperfordesq-ai)

The Federation API is an additive extension — it introduces new files only and does not modify any original TimeOverflow source code. It is licensed under the same AGPL-3.0 license as the original project.

### Federation API Files

All files listed below were created for the Federation API and are not part of the original TimeOverflow codebase:

```
app/controllers/api/v1/          — API endpoint controllers
app/models/federation_*.rb       — Federation data models
app/services/federation/         — Federation business logic
app/jobs/federation/             — Background jobs
config/initializers/federation_api.rb
config/initializers/0_api_controller_fix.rb
db/migrate/20260408*             — Database migrations
lib/tasks/federation.rake        — Rake tasks
scripts/                         — Test and setup scripts
docker-compose.federation.yml    — Docker overlay for federation testing
CLAUDE.md                        — AI assistant guide
CONTRIBUTORS.md                  — This file
```

---

## Acknowledgements

This project would not be possible without:

- The **Coopdevs** cooperative for creating and open-sourcing TimeOverflow
- The **TimeOverflow community** for over a decade of development and real-world usage
- The **Asociacion para el Desarrollo de los Bancos de Tiempo (ADBdT)** for supporting timebanking in Spain
- The **Ruby on Rails** community for the framework and ecosystem
- All timebanking communities worldwide who demonstrate that time is the most equitable currency

---

## License

This fork, including the Federation API extension, is distributed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**, in compliance with the original TimeOverflow license.

The full license text is available in the [LICENSE](LICENSE) file.
