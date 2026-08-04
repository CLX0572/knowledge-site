import { QuartzConfig } from "./quartz/cfg"
import * as Plugin from "./quartz/plugins"

/**
 * Quartz 4 Configuration
 *
 * See https://quartz.jzhao.xyz/configuration for more information.
 */
const config: QuartzConfig = {
  configuration: {
    pageTitle: "轨向的物理笔记",
    pageTitleSuffix: " | 轨向的物理笔记",
    enableSPA: true,
    enablePopovers: true,
    locale: "zh-CN",
    baseUrl: process.env.SITE_BASE_URL || "knowledge-site-aqn.pages.dev",
    ignorePatterns: ["private", "templates", ".obsidian", "物理讲义", "科目一-综合素质", "学习方法"],
    defaultDateType: "modified",
    theme: {
      fontOrigin: "local",
      cdnCaching: false,
      typography: {
        header: "Schibsted Grotesk",
        body: "Source Sans Pro",
        code: "IBM Plex Mono",
      },
      colors: {
        lightMode: {
          light: "#ffffff",
          lightgray: "#f0ecf9",
          gray: "#b8add0",
          darkgray: "#4a3f6b",
          dark: "#1a1033",
          secondary: "#7c3aed",
          tertiary: "#a78bfa",
          highlight: "rgba(124, 58, 237, 0.12)",
          textHighlight: "rgba(167, 139, 250, 0.35)",
        },
        darkMode: {
          light: "#141022",
          lightgray: "#1f1830",
          gray: "#534469",
          darkgray: "#a297be",
          dark: "#eaddff",
          secondary: "#a78bfa",
          tertiary: "#7c3aed",
          highlight: "rgba(167, 139, 250, 0.18)",
          textHighlight: "rgba(124, 58, 237, 0.3)",
        },
      },
    },
    globalState: {},
  },
  plugins: {
    transformers: [
      Plugin.FrontMatter(),
      Plugin.CreatedModifiedDate({
        priority: ["frontmatter", "git", "filesystem"],
      }),
      Plugin.SyntaxHighlighting({
        theme: {
          light: "github-light",
          dark: "github-dark",
        },
        keepBackground: false,
      }),
      Plugin.ObsidianFlavoredMarkdown({ enableInHtmlEmbed: false }),
      Plugin.GitHubFlavoredMarkdown(),
      Plugin.TableOfContents(),
      Plugin.CrawlLinks({
        markdownLinkResolution: "shortest",
        openLinksInNewTab: true,
        prettyRefs: true,
      }),
      Plugin.Description(),
      Plugin.Latex({ renderEngine: "katex", renderLegacy: false }),
    ],
    filters: [Plugin.RemoveDrafts()],
    emitters: [
      Plugin.AliasRedirects(),
      Plugin.ComponentResources(),
      Plugin.ContentPage(),
      Plugin.FolderPage(),
      Plugin.TagPage(),
      Plugin.ContentIndex({
        enableSiteMap: true,
        enableRSS: true,
      }),
      Plugin.Assets(),
      Plugin.Static(),
      Plugin.NotFoundPage(),
    ],
  },
}

export default config
