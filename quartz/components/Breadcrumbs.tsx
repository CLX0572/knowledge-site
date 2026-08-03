import { QuartzComponent, QuartzComponentConstructor, QuartzComponentProps } from "./types"
import breadcrumbsStyle from "./styles/breadcrumbs.scss"
import { FullSlug, SimpleSlug, resolveRelative, simplifySlug } from "../util/path"
import { classNames } from "../util/lang"
import { trieFromAllFiles } from "../util/ctx"

type CrumbData = {
  displayName: string
  path: string
}

interface BreadcrumbOptions {
  /**
   * Symbol between crumbs
   */
  spacerSymbol: string
  /**
   * Name of first crumb
   */
  rootName: string
  /**
   * Whether to look up frontmatter title for folders (could cause performance problems with big vaults)
   */
  resolveFrontmatterTitle: boolean
  /**
   * Whether to display the current page in the breadcrumbs.
   */
  showCurrentPage: boolean
}

const defaultOptions: BreadcrumbOptions = {
  spacerSymbol: "❯",
  rootName: "Home",
  resolveFrontmatterTitle: true,
  showCurrentPage: true,
}

function formatCrumb(displayName: string, baseSlug: FullSlug, currentSlug: SimpleSlug): CrumbData {
  return {
    displayName: displayName.replaceAll("-", " "),
    path: resolveRelative(baseSlug, currentSlug),
  }
}

export default ((opts?: Partial<BreadcrumbOptions>) => {
  const options: BreadcrumbOptions = { ...defaultOptions, ...opts }
  const Breadcrumbs: QuartzComponent = ({
    fileData,
    allFiles,
    displayClass,
    ctx,
  }: QuartzComponentProps) => {
    const trie = (ctx.trie ??= trieFromAllFiles(allFiles))
    const slugParts = fileData.slug!.split("/")
    const pathNodes = trie.ancestryChain(slugParts)

    if (!pathNodes) {
      return null
    }

    const crumbs: CrumbData[] = pathNodes.map((node, idx) => {
      const crumb = formatCrumb(node.displayName, fileData.slug!, simplifySlug(node.slug))
      if (idx === 0) {
        crumb.displayName = options.rootName
      }

      // For last node (current page), set empty path
      if (idx === pathNodes.length - 1) {
        crumb.path = ""
      }

      return crumb
    })

    if (!options.showCurrentPage) {
      crumbs.pop()
    }

    return (
      <nav class={classNames(displayClass, "breadcrumb-container")} aria-label="breadcrumbs">
        {crumbs.map((crumb, index) => {
          const isLast = index === crumbs.length - 1
          const isFolder = !isLast && !!crumb.path && (crumb.path.endsWith("/") || !crumb.path.includes("."))
          return (
            <div class="breadcrumb-element">
              {isFolder ? (
                // FIX: intermediate folder crumb -> <span> NOT <a href>. Click expands matching folder in the left Explorer.
                <span
                  class="breadcrumb-folder-crumb"
                  data-folder-slug={crumb.path}
                  role="button"
                  tabIndex={0}
                  onClick={(evt) => {
                    evt.preventDefault()
                    // Expand / scroll-to matching folder in Explorer
                    const titleText = crumb.displayName.trim()
                    const folderTitles = document.querySelectorAll(".folder-title") as NodeListOf<HTMLElement>
                    let matched: HTMLElement | null = null
                    for (const t of Array.from(folderTitles)) {
                      if ((t.textContent || "").trim() === titleText) {
                        matched = t
                        break
                      }
                    }
                    if (matched) {
                      const fc = matched.closest(".folder-container") as HTMLElement | null
                      const child = fc?.nextElementSibling as HTMLElement | null
                      if (child && !child.classList.contains("open")) {
                        const icon = fc?.querySelector(".folder-icon") as HTMLElement | null
                        icon?.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }))
                      }
                      matched.scrollIntoView({ behavior: "smooth", block: "center" })
                    }
                  }}
                >
                  {crumb.displayName}
                </span>
              ) : (
                <a href={crumb.path}>{crumb.displayName}</a>
              )}
              {!isLast && <p>{` ${options.spacerSymbol} `}</p>}
            </div>
          )
        })}
      </nav>
    )
  }
  Breadcrumbs.css = breadcrumbsStyle

  return Breadcrumbs
}) satisfies QuartzComponentConstructor
