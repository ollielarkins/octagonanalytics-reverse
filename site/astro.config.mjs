// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mermaid from 'astro-mermaid';

// The Octagon Analytics knowledge base. Two areas:
//   use/  for recruiters and managers: how to use it and how far to trust the numbers
//   run/  for admins and developers: how it is built, secured and operated
export default defineConfig({
	integrations: [
		// Must come before starlight so ```mermaid blocks are claimed first.
		mermaid({ theme: 'base', autoTheme: true }),
		starlight({
			title: 'Octagon Analytics',
			description: 'How the Octagon recruitment analytics platform works, how to use it, and how far to trust its numbers.',
			logo: { src: './src/assets/octagon-mark.svg', alt: 'Octagon' },
			favicon: '/favicon.svg',
			customCss: [
				'@fontsource-variable/inter',
				'@fontsource/poppins/600.css',
				'@fontsource/poppins/700.css',
				'./src/styles/octagon.css',
			],
			expressiveCode: {
				themes: ['github-dark-default', 'github-light'],
				styleOverrides: { borderRadius: '8px', codeFontSize: '0.86rem' },
			},
			lastUpdated: true,
			pagination: true,
			tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
			components: {
				Footer: './src/components/Footer.astro',
				PageTitle: './src/components/PageTitle.astro',
			},
			sidebar: [
				{
					label: 'Use it',
					items: [
						{ label: 'Getting started', slug: 'use/getting-started' },
						{ label: 'Your day', slug: 'use/your-day' },
						{ label: 'Commands', slug: 'use/commands' },
						{ label: 'Asking questions', slug: 'use/asking-questions' },
						{ label: 'Your inbox', slug: 'use/inbox' },
						{ label: 'Making changes safely', slug: 'use/making-changes' },
					],
				},
				{
					label: 'Trust the numbers',
					items: [
						{ label: 'KPIs and targets', slug: 'use/kpis-and-targets' },
						{ label: 'Metrics and definitions', slug: 'use/metrics' },
						{ label: 'The funnel', slug: 'use/funnel' },
						{ label: 'Data caveats', slug: 'use/data-caveats' },
						{ label: 'Glossary', slug: 'use/glossary' },
						{ label: 'FAQ', slug: 'use/faq' },
					],
				},
				{
					label: 'Run it',
					items: [
						{ label: 'Architecture', slug: 'run/architecture' },
						{ label: 'Sync and webhooks', slug: 'run/sync' },
						{ label: 'The metrics layer', slug: 'run/metrics-layer' },
						{ label: 'Edge functions', slug: 'run/edge-functions' },
						{ label: 'The connector', slug: 'run/connector' },
						{ label: 'Tools reference', slug: 'run/tools' },
						{ label: 'Plugins and commands', slug: 'run/plugins' },
						{ label: 'Slack and the Coach', slug: 'run/slack' },
						{ label: 'Security model', slug: 'run/security' },
					],
				},
				{
					label: 'Operate it',
					items: [
						{ label: 'Operations runbook', slug: 'run/runbook' },
						{ label: 'Contributing', slug: 'run/contributing' },
						{ label: 'Writing these docs', slug: 'run/writing-docs' },
					],
				},
			],
		}),
	],
});
