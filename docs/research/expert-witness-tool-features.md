# Expert Witness AI Research Tool — Feature Research

## Target: MVP for QCAT and NCAT Building Dispute Cases

**Date:** 2026-03-06

---

## 1. Tribunal Overview

### QCAT — Queensland Civil and Administrative Tribunal
- Established under the **Queensland Civil and Administrative Tribunal Act 2009 (Qld)**
- Hears domestic and commercial building disputes
- **Pre-requisite**: Mandatory QBCC dispute resolution before QCAT application (letter from QBCC required)
- Parties generally self-represent; lawyer representation requires tribunal permission
- Resolution methods: hearing, mediation, compulsory conference
- Online case management via **QCase** portal
- Decisions published at [queenslandjudgments.com.au/caselaw/qcat](https://www.queenslandjudgments.com.au/caselaw/qcat)
- QCAT Act under review 2025–26 (report due July 2026)

### NCAT — NSW Civil and Administrative Tribunal
- Established under the **Civil and Administrative Tribunal Act 2013 (NSW)**
- Consumer and Commercial Division handles home building claims
- Monetary thresholds:
  - Claims **under $30,000**: simplified process
  - Claims **$30,000–$500,000**: standard process
  - Claims **over $500,000**: referred to Supreme Court
- Expert conclaves are commonly ordered (joint expert meetings to narrow issues)
- Decisions published at [ncat.nsw.gov.au/publications-and-resources/published-decisions.html](https://ncat.nsw.gov.au/publications-and-resources/published-decisions.html)

---

## 2. Key Legislation

### Queensland
| Legislation | Relevance |
|---|---|
| **Queensland Building and Construction Commission Act 1991** | QBCC licensing, statutory warranties, defect definitions, dispute resolution pre-requisites |
| **Queensland Civil and Administrative Tribunal Act 2009** | QCAT jurisdiction, powers, procedures |
| **Building Act 1975 (Qld)** | Building approvals, compliance requirements |
| **Domestic Building Contracts Act 2000 (Qld)** | Contract requirements for residential work |

### New South Wales
| Legislation | Relevance |
|---|---|
| **Home Building Act 1989 (NSW)** | Statutory warranties (s18B), major/minor defect definitions (s18E), limitation periods, insurance requirements |
| **Civil and Administrative Tribunal Act 2013 (NSW)** | NCAT jurisdiction, powers, procedures |
| **Design and Building Practitioners Act 2020 (NSW)** | Duty of care, design compliance declarations |
| **Residential Apartment Buildings (Compliance and Enforcement Powers) Act 2020 (NSW)** | Building compliance powers |

### Key Warranty Periods (NSW — Home Building Act s18E)
- **Major defects**: 6 years from completion
- **Other defects (minor)**: 2 years from completion
- **Major defect** = defect in a major element that is attributable to defective design/workmanship/materials AND causes or is likely to cause inability to inhabit/use, destruction, threat of collapse, or is inconsistent with fire safety requirements

### Key Warranty Periods (QLD — QBCC Act)
- **Structural defects**: 6 years and 6 months from completion
- **Non-structural defects**: 6 months from completion (residential), 12 months (non-residential)

---

## 3. Australian Standards Commonly Referenced

| Standard | Topic |
|---|---|
| **NCC (National Construction Code)** | Overarching performance requirements for all building work |
| **AS 2870** | Residential slabs and footings |
| **AS 3600** | Concrete structures |
| **AS 3740** | Waterproofing of domestic wet areas |
| **AS 4654** | Waterproofing of external above-ground areas |
| **AS 1684** | Residential timber-framed construction |
| **AS 3500** | Plumbing and drainage |
| **AS 1170** | Structural design actions (loads) |
| **AS 4100** | Steel structures |
| **AS 2047** | Windows and external glazed doors |
| **AS 4055** | Wind loads for housing |
| **AS 3959** | Construction in bushfire-prone areas |
| **AS/NZS 3000 (Wiring Rules)** | Electrical installations |

---

## 4. Common Building Defect Categories

Based on Australian tribunal case analysis:

1. **Waterproofing failures** — wet areas, balconies, roofs, basements
2. **Structural cracking** — slabs, walls, footings
3. **Incomplete or defective tiling** — falls, adhesion, grout
4. **Roof defects** — leaks, incorrect falls, flashing failures
5. **Drainage/plumbing issues** — incorrect falls, blocked drains, non-compliant work
6. **Window/door defects** — leaks, incorrect installation, non-compliance with AS 2047
7. **Painting/coating defects** — peeling, blistering, inadequate preparation
8. **Electrical non-compliance** — non-compliant installations, missing safety switches
9. **Fire safety deficiencies** — compartmentation, detection, egress
10. **Timber framing defects** — non-compliant connections, inadequate bracing

---

## 5. Expert Witness Requirements

### NCAT — Procedural Direction 3 (Expert Evidence)
- Expert's **qualifications and experience** must be stated
- Expert must acknowledge **overriding duty to the tribunal** (not to the party retaining them)
- Report must include a **declaration of independence**
- Expert must only opine **within their area of expertise**
- Report must reference **facts, data and assumptions** relied upon
- Report must distinguish between **observed facts** and **opinions**
- Joint expert conclaves may be directed to narrow issues

### QCAT — Expert Requirements
- Similar requirements under the Uniform Civil Procedure Rules (UCPR)
- Expert must be independent and owe a duty to the tribunal
- Qualifications must be stated
- All assumptions and materials relied upon must be disclosed

### Scott Schedules
- **Standard format** for presenting defect claims in both QCAT and NCAT
- Tabular format: Item | Description of Defect | Applicable Standard/Code | Claimant's Position | Respondent's Position | Expert Opinion | Cost to Rectify
- NCAT provides an [official Scott Schedule template](https://ncat.nsw.gov.au/documents/forms/ccd_form_scott_schedule_defective_workmanship.pdf)

---

## 6. Data Sources for Case Research

| Source | Coverage | URL |
|---|---|---|
| **AustLII** | Comprehensive Australian legal database — QCAT & NCAT decisions, legislation, standards | [austlii.edu.au](https://www.austlii.edu.au/databases.html) |
| **Queensland Judgments** | QCAT decisions | [queenslandjudgments.com.au/caselaw/qcat](https://www.queenslandjudgments.com.au/caselaw/qcat) |
| **NCAT Published Decisions** | NCAT decisions | [ncat.nsw.gov.au/publications-and-resources/published-decisions.html](https://ncat.nsw.gov.au/publications-and-resources/published-decisions.html) |
| **NSW CaseLaw** | NSW tribunal/court decisions | [caselaw.nsw.gov.au](https://www.caselaw.nsw.gov.au/) |
| **QLD Legislation** | Queensland statutes and regulations | [legislation.qld.gov.au](https://www.legislation.qld.gov.au/) |
| **NSW Legislation** | NSW statutes and regulations | [legislation.nsw.gov.au](https://legislation.nsw.gov.au/) |
| **NCC** | National Construction Code (building standards) | [ncc.abcb.gov.au](https://ncc.abcb.gov.au/) |

---

## 7. MVP Feature Set (Prioritised)

### Tier 1 — Core (MVP Must-Haves)

#### A. Case Law Search & Analysis
1. **Precedent search** — Search QCAT and NCAT building dispute decisions via AustLII / Queensland Judgments / NSW CaseLaw, filtered by defect type, outcome, and date range
2. **Case summariser** — Given a case citation or URL, extract key facts, defects alleged, standards referenced, tribunal findings, quantum awarded, and legal principles applied
3. **Similar case finder** — Given a set of defects and facts, find the most relevant precedent cases and extract the key holdings

#### B. Legislation & Standards Reference
4. **Defect-to-standard mapper** — Given a defect description, identify the applicable Australian Standards, NCC provisions, and statutory warranty provisions
5. **Warranty period calculator** — Given completion date, defect type (major/minor), and jurisdiction (QLD/NSW), calculate whether the claim is within the limitation period
6. **Legislation quick-reference** — Retrieve relevant sections of the Home Building Act, QBCC Act, and associated regulations for a given issue

#### C. Document Generation
7. **Scott Schedule generator** — Generate a Scott Schedule in the NCAT-compliant tabular format from structured defect data, with columns for each party's position and expert opinion
8. **Expert report template** — Generate a report skeleton compliant with NCAT PD3 / QCAT UCPR requirements, including all mandatory sections (qualifications, independence declaration, scope, methodology, opinions, assumptions)

### Tier 2 — High Value Additions

#### D. Compliance & Validation
9. **Expert report compliance checker** — Validate that a draft expert report meets NCAT PD3 requirements (qualifications stated, independence declared, scope limited to expertise, proper formatting)
10. **QCAT UCPR compliance checker** — Similarly validate for QCAT requirements
11. **Defect classifier** — Apply the statutory test (e.g. s18E(4) of the Home Building Act) to classify a defect as major or minor, with reasoning

#### E. Jurisdiction & Process Guidance
12. **Jurisdiction router** — Given claim value and location (QLD vs NSW), determine the correct tribunal/court and applicable monetary limits
13. **Pre-filing checklist** — Guide users through QBCC or NSW Fair Trading pre-filing requirements
14. **Limitation period calculator** — Calculate whether a claim is within the relevant warranty/limitation period

#### F. Knowledge Base
15. **Defect taxonomy** — Structured database of common building defect categories with descriptions, typical causes, applicable standards, and typical rectification methods
16. **Expert discipline matcher** — Recommend the correct expert discipline (structural engineer, waterproofing specialist, fire safety engineer, quantity surveyor) for each defect type
17. **Photo/evidence guidance** — Suggest what photographic and documentary evidence is needed for each defect type

### Tier 3 — Future Enhancements

18. **Quantum analysis** — Analyse historical awards/settlements for similar defect types to estimate likely quantum ranges
19. **Cross-jurisdictional comparison** — Compare how QCAT and NCAT treat similar defect types differently
20. **Live legislation monitoring** — Track amendments to relevant legislation and standards
21. **Expert conclave preparation** — Generate conclave agendas and joint report templates per NCAT requirements
22. **Cost estimation** — Integration with construction cost databases (e.g., Rawlinsons, Cordell) for rectification cost estimation

---

## 8. Architecture Fit with Alloy

Alloy is a minimal, OTP-native agent framework for Elixir. The expert witness tool would be built **on top of Alloy** using its extension points:

### Custom Tools (implement `Alloy.Tool` behaviour)
- `Tool.CaseLawSearch` — Query AustLII/Queensland Judgments/NSW CaseLaw APIs
- `Tool.LegislationLookup` — Retrieve specific sections of relevant statutes
- `Tool.ScottSchedule` — Generate Scott Schedule documents
- `Tool.DefectClassifier` — Classify defects and map to standards
- `Tool.ExpertReportTemplate` — Generate compliant report skeletons
- `Tool.WarrantyCalculator` — Calculate limitation periods

### Middleware (implement `Alloy.Middleware` behaviour)
- `Middleware.JurisdictionContext` — Automatically inject jurisdiction-specific context (QLD vs NSW) based on the case being worked on
- `Middleware.ComplianceChecker` — Validate generated documents against PD3/UCPR requirements before returning to user

### System Prompt
- Domain-specific system prompt encoding expert witness duties, tribunal procedures, and Australian building law fundamentals
- Structured to ensure the agent always cites sources and distinguishes facts from opinions

### Data Layer (outside Alloy — application responsibility)
- Case law index (AustLII scrape or API integration)
- Legislation database (versioned statute sections)
- Defect taxonomy database
- Australian Standards reference database
- Template storage for Scott Schedules and expert reports

---

## 9. Technical Considerations

### Data Access Challenges
- **AustLII** provides free access but no official API — may need web scraping or partnership
- **Queensland Judgments** has a search interface but no public API
- **NSW CaseLaw** has a search interface with some structured data
- **Australian Standards** are copyrighted — can reference standard numbers and titles but cannot reproduce content
- **NCC** has online access but content is paywalled for full offline use

### Compliance Requirements
- Tool must clearly distinguish AI-generated content from expert opinion
- Generated reports must include disclaimers that they are drafts requiring expert review
- The tool assists experts — it does not replace expert judgment
- Must handle personally identifiable information (PII) in case documents appropriately

### Performance Requirements
- Case law searches should return results within reasonable time (AustLII can be slow)
- Document generation should handle large Scott Schedules (50+ defect items)
- Context window management critical for long case documents (Alloy's compactor helps here)
