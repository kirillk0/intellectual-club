<script setup lang="ts">
/**
 * SVG icon component. Loads monochrome icons from individual .svg files.
 * Icons are imported as Vue components via vite-svg-loader.
 */
import { computed, type Component } from 'vue';

import CopyIcon from './svg/copy.svg';
import EditIcon from './svg/edit.svg';
import DeleteIcon from './svg/delete.svg';
import PlayIcon from './svg/play.svg';
import ShareIncomingIcon from './svg/share-incoming.svg';
import ShareOutgoingIcon from './svg/share-outgoing.svg';
import SortAlphaIcon from './svg/sort-alpha.svg';
import SortTimeIcon from './svg/sort-time.svg';
import BotIcon from './svg/bot.svg';
import ChatIcon from './svg/chat.svg';
import ArrowUpIcon from './svg/arrow-up.svg';
import ArrowDownIcon from './svg/arrow-down.svg';
import ShieldIcon from './svg/shield.svg';
import SidebarIcon from './svg/sidebar.svg';
import SlidersIcon from './svg/sliders.svg';
import UserIcon from './svg/user.svg';
import WrenchIcon from './svg/wrench.svg';
import MusicIcon from './svg/music.svg';
import VideoIcon from './svg/video.svg';
import SpreadsheetIcon from './svg/spreadsheet.svg';
import DocumentIcon from './svg/document.svg';
import CodeIcon from './svg/code.svg';
import FilterIcon from './svg/filter.svg';
import BranchIcon from './svg/branch.svg';
import BookmarkIcon from './svg/bookmark.svg';
import CheckIcon from './svg/check.svg';
import ChevronLeftIcon from './svg/chevron-left.svg';
import ChevronRightIcon from './svg/chevron-right.svg';
import RetryIcon from './svg/retry.svg';
import FileTextIcon from './svg/file-text.svg';
import FileGenericIcon from './svg/file-generic.svg';
import FileImageIcon from './svg/file-image.svg';
import FilePdfIcon from './svg/file-pdf.svg';
import FileDocIcon from './svg/file-doc.svg';
import FileSpreadsheetIcon from './svg/file-spreadsheet.svg';
import FilePresentationIcon from './svg/file-presentation.svg';
import FileAudioIcon from './svg/file-audio.svg';
import FileVideoIcon from './svg/file-video.svg';
import FileCodeIcon from './svg/file-code.svg';
import FileMarkdownIcon from './svg/file-markdown.svg';
import FileArchiveIcon from './svg/file-archive.svg';
import ToolArtifactIcon from './svg/tool-artifact.svg';
import ToolBookIcon from './svg/tool-book.svg';
import ToolGlobeIcon from './svg/tool-globe.svg';
import ToolOutletIcon from './svg/tool-outlet.svg';
import ToolPlugIcon from './svg/tool-plug.svg';
import ToolSearchIcon from './svg/tool-search.svg';
import ToolTerminalIcon from './svg/tool-terminal.svg';

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
  'document': DocumentIcon,
  'code': CodeIcon,
  'filter': FilterIcon,
  'branch': BranchIcon,
  'bookmark': BookmarkIcon,
  'check': CheckIcon,
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
