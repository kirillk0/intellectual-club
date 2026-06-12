<script setup lang="ts">
/**
 * SVG icon component. Loads monochrome icons from individual .svg files.
 * Icons are imported as Vue components via vite-svg-loader.
 */
import { computed, type Component } from 'vue';

import CopyIcon from './svg/copy.svg?component';
import EditIcon from './svg/edit.svg?component';
import DeleteIcon from './svg/delete.svg?component';
import PlayIcon from './svg/play.svg?component';
import ShareIncomingIcon from './svg/share-incoming.svg?component';
import ShareOutgoingIcon from './svg/share-outgoing.svg?component';
import SortAlphaIcon from './svg/sort-alpha.svg?component';
import SortTimeIcon from './svg/sort-time.svg?component';
import BotIcon from './svg/bot.svg?component';
import ChatIcon from './svg/chat.svg?component';
import ArrowUpIcon from './svg/arrow-up.svg?component';
import ArrowDownIcon from './svg/arrow-down.svg?component';
import ShieldIcon from './svg/shield.svg?component';
import SidebarIcon from './svg/sidebar.svg?component';
import SlidersIcon from './svg/sliders.svg?component';
import UserIcon from './svg/user.svg?component';
import WrenchIcon from './svg/wrench.svg?component';
import MusicIcon from './svg/music.svg?component';
import VideoIcon from './svg/video.svg?component';
import SpreadsheetIcon from './svg/spreadsheet.svg?component';
import BarChartIcon from './svg/bar-chart.svg?component';
import DocumentIcon from './svg/document.svg?component';
import CodeIcon from './svg/code.svg?component';
import FilterIcon from './svg/filter.svg?component';
import BranchIcon from './svg/branch.svg?component';
import BookmarkIcon from './svg/bookmark.svg?component';
import CheckIcon from './svg/check.svg?component';
import MoreHorizontalIcon from './svg/more-horizontal.svg?component';
import ChevronLeftIcon from './svg/chevron-left.svg?component';
import ChevronRightIcon from './svg/chevron-right.svg?component';
import RetryIcon from './svg/retry.svg?component';
import FileTextIcon from './svg/file-text.svg?component';
import FileGenericIcon from './svg/file-generic.svg?component';
import FileImageIcon from './svg/file-image.svg?component';
import FilePdfIcon from './svg/file-pdf.svg?component';
import FileDocIcon from './svg/file-doc.svg?component';
import FileSpreadsheetIcon from './svg/file-spreadsheet.svg?component';
import FilePresentationIcon from './svg/file-presentation.svg?component';
import FileAudioIcon from './svg/file-audio.svg?component';
import FileVideoIcon from './svg/file-video.svg?component';
import FileCodeIcon from './svg/file-code.svg?component';
import FileMarkdownIcon from './svg/file-markdown.svg?component';
import FileArchiveIcon from './svg/file-archive.svg?component';
import ToolArtifactIcon from './svg/tool-artifact.svg?component';
import ToolBookIcon from './svg/tool-book.svg?component';
import ToolGlobeIcon from './svg/tool-globe.svg?component';
import ToolOutletIcon from './svg/tool-outlet.svg?component';
import ToolPlugIcon from './svg/tool-plug.svg?component';
import ToolSearchIcon from './svg/tool-search.svg?component';
import ToolTerminalIcon from './svg/tool-terminal.svg?component';

const iconMap: Record<string, Component> = {
  'copy': CopyIcon,
  'edit': EditIcon,
  'delete': DeleteIcon,
  'play': PlayIcon,
  'share-incoming': ShareIncomingIcon,
  'share-outgoing': ShareOutgoingIcon,
  'sort-alpha': SortAlphaIcon,
  'sort-time': SortTimeIcon,
  'bot': BotIcon,
  'chat': ChatIcon,
  'arrow-up': ArrowUpIcon,
  'arrow-down': ArrowDownIcon,
  'shield': ShieldIcon,
  'sidebar': SidebarIcon,
  'sliders': SlidersIcon,
  'user': UserIcon,
  'wrench': WrenchIcon,
  'music': MusicIcon,
  'video': VideoIcon,
  'spreadsheet': SpreadsheetIcon,
  'bar-chart': BarChartIcon,
  'document': DocumentIcon,
  'code': CodeIcon,
  'filter': FilterIcon,
  'branch': BranchIcon,
  'bookmark': BookmarkIcon,
  'check': CheckIcon,
  'more-horizontal': MoreHorizontalIcon,
  'chevron-left': ChevronLeftIcon,
  'chevron-right': ChevronRightIcon,
  'retry': RetryIcon,
  'file-text': FileTextIcon,
  'file-generic': FileGenericIcon,
  'file-image': FileImageIcon,
  'file-pdf': FilePdfIcon,
  'file-doc': FileDocIcon,
  'file-spreadsheet': FileSpreadsheetIcon,
  'file-presentation': FilePresentationIcon,
  'file-audio': FileAudioIcon,
  'file-video': FileVideoIcon,
  'file-code': FileCodeIcon,
  'file-markdown': FileMarkdownIcon,
  'file-archive': FileArchiveIcon,
  'tool-artifact': ToolArtifactIcon,
  'tool-book': ToolBookIcon,
  'tool-globe': ToolGlobeIcon,
  'tool-outlet': ToolOutletIcon,
  'tool-plug': ToolPlugIcon,
  'tool-search': ToolSearchIcon,
  'tool-terminal': ToolTerminalIcon,
};

const props = defineProps<{
  name: string;
  size?: number | string;
}>();

const iconComponent = computed(() => iconMap[props.name] || null);
</script>

<template>
  <component
    v-if="iconComponent"
    :is="iconComponent"
    class="svg-icon"
    :width="size || '1em'"
    :height="size || '1em'"
    aria-hidden="true"
  />
</template>

<style scoped>
.svg-icon {
  display: inline-block;
  vertical-align: middle;
  flex-shrink: 0;
}
</style>
